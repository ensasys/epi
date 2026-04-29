import sys.io.File;
import sys.FileSystem;
import sys.io.Process;
import haxe.Json;
import hscript.Parser;
import hscript.Interp;

// ---------------------------
// ERROR HANDLING & CONTEXT
// ---------------------------
class Context {
    public static var line:String = "";
    public static var source:String = "main";
}

class Main {
    // ---------------------------
    // GLOBAL ENVIRONMENT
    // ---------------------------
    static var globals_env:Map<String, Dynamic> = [];
    static var methods:Map<String, Dynamic> = [];
    static var interp:Interp;
    static var parser:Parser;

    // ---------------------------
    // HELPER FUNCTIONS
    // ---------------------------
    
    static function set_context(line_content:String):Void {
        Context.line = line_content;
    }

    static function log_error(msg:String, detail:String = null):Void {
        Sys.stderr().writeString('\n[!] Runtime Error: $msg\n');
        if (detail != null) {
            Sys.stderr().writeString('    Details: $detail\n');
        }
        Sys.stderr().writeString('    Near code: >> ${Context.line}\n\n');
    }

    /**
     * Splits arguments by comma, but only at the top level and outside quotes.
     */
    static function split_args(arg_str:String):Array<String> {
        try {
            var args:Array<String> = [];
            var current:StringBuf = new StringBuf();
            var depth:Int = 0;
            var in_sq:Bool = false;
            var in_dq:Bool = false;
            var esc:Bool = false;

            for (i in 0...arg_str.length) {
                var ch = arg_str.charAt(i);

                if (esc) {
                    current.add(ch);
                    esc = false;
                    continue;
                }

                if (ch == '\\') {
                    current.add(ch);
                    esc = true;
                    continue;
                }

                if (ch == "'" && !in_dq) {
                    in_sq = !in_sq;
                    current.add(ch);
                    continue;
                }

                if (ch == '"' && !in_sq) {
                    in_dq = !in_dq;
                    current.add(ch);
                    continue;
                }

                if (!in_sq && !in_dq) {
                    if (ch == '(' || ch == '[') {
                        depth++;
                    } else if (ch == ')' || ch == ']') {
                        depth--;
                    }

                    if (ch == ',' && depth == 0) {
                        args.push(StringTools.trim(current.toString()));
                        current = new StringBuf();
                        continue;
                    }
                }
                current.add(ch);
            }

            if (current.length > 0) {
                args.push(StringTools.trim(current.toString()));
            }
            return args;
        } catch (e:Dynamic) {
            log_error("Failed to split arguments", Std.string(e));
            return [];
        }
    }

    static function process_complex_name(inner_content:String, local_env:Map<String, Dynamic>):String {
        try {
            var parts = split_args(inner_content);
            var evaluated_parts = [for (p in parts) Std.string(eval_expr(p, local_env))];
            return evaluated_parts.join(", ");
        } catch (e:Dynamic) {
            log_error("Failed to process complex variable name", Std.string(e));
            return "ERROR_VAR";
        }
    }

    static function remove_inline_comment(line:String):String {
        if (line == null) return line;
        var out:StringBuf = new StringBuf();
        var in_sq = false;
        var in_dq = false;
        var esc = false;
        var i = 0;
        var L = line.length;

        while (i < L) {
            var ch = line.charAt(i);
            if (esc) {
                out.add(ch);
                esc = false;
                i++;
                continue;
            }
            if (ch == '\\') {
                out.add(ch);
                esc = true;
                i++;
                continue;
            }
            if (ch == "'" && !in_dq) {
                in_sq = !in_sq;
                out.add(ch);
                i++;
                continue;
            }
            if (ch == '"' && !in_sq) {
                in_dq = !in_dq;
                out.add(ch);
                i++;
                continue;
            }
            // detect // when not inside quotes
            if (ch == '/' && !in_sq && !in_dq && (i + 1) < L && line.charAt(i + 1) == '/') {
                break;
            }
            out.add(ch);
            i++;
        }
        return out.toString();
    }

    // ---------------------------
    // SYSTEM FUNCTIONS
    // ---------------------------
    static var SYSTEM_FUNCS = [
        'print' => true, 'array_add' => true, 'array_pop' => true, 'pop' => true,
        'split' => true, 'join' => true, 'read_file' => true, 'write_file' => true
    ];

    static function call_system_function(func_name:String, arg_content:String, local_env:Map<String, Dynamic>):Dynamic {
        var name = func_name;

        if (name == 'print') {
            var val = eval_expr(arg_content, local_env);
            Sys.println(Std.string(val));
            return val;
        }

        var args = split_args(arg_content);

        try {
            if (name == 'array_add') {
                if (args.length >= 2) {
                    var target_arr_name = StringTools.trim(args[0]);
                    var val_to_add = eval_expr(args[1], local_env);
                    
                    var target_list:Array<Dynamic> = null;
                    if (local_env != null && local_env.exists(target_arr_name)) {
                        target_list = local_env[target_arr_name];
                    } else if (globals_env.exists(target_arr_name)) {
                        target_list = globals_env[target_arr_name];
                    }

                    if (Std.isOfType(target_list, Array)) {
                        target_list.push(val_to_add);
                        return target_list;
                    } else {
                        log_error("array_add failed: '" + target_arr_name + "' is not a list/array.");
                    }
                }
                return 0;
            }

            if (name == 'array_pop' || name == 'pop') {
                if (args.length >= 1) {
                    var target_arr_name = StringTools.trim(args[0]);
                    var target_list:Array<Dynamic> = null;
                    if (local_env != null && local_env.exists(target_arr_name)) {
                        target_list = local_env[target_arr_name];
                    } else {
                        target_list = globals_env[target_arr_name];
                    }

                    if (Std.isOfType(target_list, Array) && target_list.length > 0) {
                        return target_list.pop();
                    } else if (Std.isOfType(target_list, Array) && target_list.length == 0) {
                        log_error("Cannot pop from empty array '" + target_arr_name + "'");
                    } else {
                        log_error("pop failed: '" + target_arr_name + "' is not a list.");
                    }
                }
                return 0;
            }

            if (name == 'split') {
                if (args.length >= 1) {
                    var s = Std.string(eval_expr(args[0], local_env));
                    if (s == "null") s = "";
                    var delim:String = " ";
                    if (args.length > 1) {
                        delim = Std.string(eval_expr(args[1], local_env));
                    }
                    
                    if (delim == null || delim == "null" || delim == "") return s.split(" "); // Simulating python .split() whitespace behavior roughly
                    return s.split(delim);
                }
                return [];
            }

            if (name == 'join') {
                if (args.length >= 1) {
                    var lst = eval_expr(args[0], local_env);
                    var delim = (args.length > 1) ? Std.string(eval_expr(args[1], local_env)) : "";
                    if (!Std.isOfType(lst, Array)) {
                        return Std.string(lst);
                    }
                    return (cast lst:Array<Dynamic>).join(delim);
                }
                return "";
            }

            if (name == 'read_file') {
                if (args.length >= 1) {
                    var fname = Std.string(eval_expr(args[0], local_env));
                    try {
                        return File.getContent(fname);
                    } catch (e:Dynamic) {
                        log_error('File error: $fname', Std.string(e));
                        return "";
                    }
                }
                return "";
            }

            if (name == 'write_file') {
                if (args.length >= 2) {
                    var fname = Std.string(eval_expr(args[0], local_env));
                    var data = eval_expr(args[1], local_env);
                    try {
                        // Create directory if needed
                        var path = new haxe.io.Path(fname);
                        var dir = path.dir;
                        if (dir != null && dir != "" && !FileSystem.exists(dir)) {
                            FileSystem.createDirectory(dir);
                        }
                        File.saveContent(fname, Std.string(data));
                        return true;
                    } catch (e:Dynamic) {
                        log_error('Error writing file $fname', Std.string(e));
                        return false;
                    }
                }
                return false;
            }

        } catch (e:Dynamic) {
            log_error("System function '" + name + "' crashed", Std.string(e));
            // Return appropriate defaults
            if (name == 'array_add' || name == 'array_pop' || name == 'pop') return 0;
            if (name == 'split') return [];
            if (name == 'join') return "";
            if (name == 'read_file') return "";
            if (name == 'write_file') return false;
        }
        return 0;
    }

    static function find_bracket_call(expr:String):{s_idx:Int, end_idx:Int, fname:String, content:String} {
        var in_sq = false;
        var in_dq = false;
        var esc = false;
        var i = 0;
        var L = expr.length;

        while (i < L) {
            var ch = expr.charAt(i);

            if (esc) { esc = false; i++; continue; }
            if (ch == '\\') { esc = true; i++; continue; }
            if (ch == "'" && !in_dq) { in_sq = !in_sq; i++; continue; }
            if (ch == '"' && !in_sq) { in_dq = !in_dq; i++; continue; }

            if (!in_sq && !in_dq) {
                if (ch == '[') {
                    var j = i - 1;
                    // Skip whitespace backwards
                    while (j >= 0 && (StringTools.isSpace(expr, j))) j--;
                    
                    // Identify Name
                    if (j >= 0) {
                        var k = j;
                        // Simple alphanum check manually
                        while (k >= 0) {
                            var c = expr.charCodeAt(k);
                            // a-z, A-Z, 0-9, _
                            if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95)) {
                                break;
                            }
                            k--;
                        }
                        
                        var name = expr.substring(k + 1, j + 1);
                        // Check if valid name (not starting with digit)
                        var firstC = name.charCodeAt(0);
                        if (name.length > 0 && !(firstC >= 48 && firstC <= 57)) {
                            var start_bracket_idx = i;
                            var depth = 1;
                            var m = i + 1;
                            
                            var inner_sq = false;
                            var inner_dq = false;
                            var inner_esc = false;

                            while (m < L && depth > 0) {
                                var c2 = expr.charAt(m);
                                if (inner_esc) { inner_esc = false; m++; continue; }
                                if (c2 == '\\') { inner_esc = true; m++; continue; }
                                
                                if (c2 == "'" && !inner_dq) { inner_sq = !inner_sq; }
                                else if (c2 == '"' && !inner_sq) { inner_dq = !inner_dq; }
                                
                                if (!inner_sq && !inner_dq) {
                                    if (c2 == '[') depth++;
                                    else if (c2 == ']') depth--;
                                }
                                m++;
                            }

                            if (depth == 0) {
                                return {
                                    s_idx: k + 1,
                                    end_idx: m,
                                    fname: name,
                                    content: expr.substring(start_bracket_idx + 1, m - 1)
                                };
                            }
                        }
                    }
                }
            }
            i++;
        }
        return null;
    }

    static function unescape_string_literal(s:String):String {
        var out = new StringBuf();
        var i = 0;
        var L = s.length;
        while (i < L) {
            var ch = s.charAt(i);
            if (ch == '\\' && i + 1 < L) {
                var nxt = s.charAt(i + 1);
                switch(nxt) {
                    case 'n': out.add('\n');
                    case 't': out.add('\t');
                    case 'r': out.add('\r');
                    case '\\': out.add('\\');
                    case '"': out.add('"');
                    case "'": out.add("'");
                    case '0': out.addChar(0);
                    default: out.add(nxt);
                }
                i += 2;
                continue;
            }
            // Hash escaping
            if (ch == '#' && i + 1 < L) {
                var nxt = s.charAt(i + 1);
                if (nxt == '#') { out.add('#'); i += 2; continue; }
                switch(nxt) {
                    case 'n': out.add('\n');
                    case 't': out.add('\t');
                    case 's': out.add(' ');
                    case 'r': out.add('\r');
                    case '"': out.add('"');
                    case "'": out.add("'");
                    case '0': out.addChar(0);
                    default: out.add('#'); i++; continue; // Just keep hash
                }
                i += 2;
                continue;
            }
            out.add(ch);
            i++;
        }
        return out.toString();
    }

static function eval_expr(expr:Dynamic, local_env:Map<String, Dynamic> = null):Dynamic {
        if (local_env == null) local_env = [];
        var s_expr = StringTools.trim(Std.string(expr));
        if (s_expr.length == 0) return 0;

        // 1. Array Definitions
        while (s_expr.indexOf("a(") != -1 && s_expr.indexOf(")a") != -1) {
            s_expr = StringTools.replace(s_expr, "a(", "[");
            s_expr = StringTools.replace(s_expr, ")a", "]");
        }

        // Literal String Check
        if ((StringTools.startsWith(s_expr, '"') && StringTools.endsWith(s_expr, '"')) ||
            (StringTools.startsWith(s_expr, "'") && StringTools.endsWith(s_expr, "'"))) {
            return unescape_string_literal(s_expr.substring(1, s_expr.length - 1));
        }

        // 2. Array Retrieval r(...)r
        var regex_arr = ~/([a-zA-Z_]\w*)\s*r\(\s*(.*?)\s*\)r/;
        while (regex_arr.match(s_expr)) {
            var var_name = regex_arr.matched(1);
            var args_str = regex_arr.matched(2);
            
            var obj:Dynamic = null;
            if (local_env.exists(var_name)) obj = local_env[var_name];
            else if (globals_env.exists(var_name)) obj = globals_env[var_name];

            var replacement = "0";
            if (Std.isOfType(obj, Array)) {
                try {
                    var raw_indices = split_args(args_str);
                    var current_val = obj;
                    for (raw_idx in raw_indices) {
                        var idx = Std.int(eval_expr(raw_idx, local_env));
                        current_val = cast(current_val, Array<Dynamic>)[idx];
                    }
                    if (Std.isOfType(current_val, String)) replacement = Json.stringify(current_val);
                    else replacement = Std.string(current_val);
                } catch (e:Dynamic) {
                    log_error("Error accessing array " + var_name);
                }
            } else {
                log_error("Cannot index " + var_name + ", not an array");
            }
            s_expr = regex_arr.matchedLeft() + replacement + regex_arr.matchedRight();
        }

        // 3. System function calls
        try {
            while (true) {
                var found = find_bracket_call(s_expr);
                if (found == null) break;

                if (SYSTEM_FUNCS.exists(found.fname)) {
                    var res = call_system_function(found.fname, found.content, local_env);
                    var repl = (Std.isOfType(res, String) || Std.isOfType(res, Array)) ?
                        Json.stringify(res) : Std.string(res);
                    s_expr = s_expr.substring(0, found.s_idx) + repl + s_expr.substring(found.end_idx);
                } else {
                    break;
                }
            }
        } catch(e:Dynamic) {
            log_error("Error parsing system function call", Std.string(e));
        }

        // 4. Custom Method Calls
        try {
            var regex_method = ~/([a-zA-Z_]\w*)\s*\(/;
            var search_pos = 0; // Iterate through string without breaking on non-methods

            while (regex_method.matchSub(s_expr, search_pos)) {
                var func_name = regex_method.matched(1);
                var match_pos = regex_method.matchedPos();
                
                // If this isn't a known method, skip it and continue searching
                if (!methods.exists(func_name)) {
                    search_pos = match_pos.pos + match_pos.len;
                    continue;
                }

                var start_idx = match_pos.pos + match_pos.len;
                var depth = 1;
                var end_idx = -1;

                // Robust bracket finding that ignores quotes
                var i = start_idx;
                var in_sq = false;
                var in_dq = false;
                var esc = false;
                
                while (i < s_expr.length) {
                    var ch = s_expr.charAt(i);
                    if (esc) { esc = false; i++; continue; }
                    if (ch == '\\') { esc = true; i++; continue; }
                    if (ch == "'" && !in_dq) { in_sq = !in_sq; }
                    else if (ch == '"' && !in_sq) { in_dq = !in_dq; }

                    if (!in_sq && !in_dq) {
                        if (ch == '(') depth++;
                        else if (ch == ')') depth--;
                        
                        if (depth == 0) {
                            end_idx = i;
                            break;
                        }
                    }
                    i++;
                }

                if (end_idx == -1) {
                    // Mismatched brackets, skip this match to prevent infinite loop
                    search_pos = match_pos.pos + match_pos.len;
                    continue;
                }

                var arg_content = s_expr.substring(start_idx, end_idx);
                var raw_args = split_args(arg_content);
                var evaluated_args = [for(a in raw_args) eval_expr(a, local_env)];
                
                var res = execute_method(func_name, evaluated_args);
                
                // Ensure strings are quoted so HScript treats them as literals, not variables
                var repl_val = (Std.isOfType(res, String)) ? Json.stringify(res) : Std.string(res);
                
                s_expr = s_expr.substring(0, match_pos.pos) + repl_val + s_expr.substring(end_idx + 1);
                
                // Reset search position because string length changed
                search_pos = 0;
            }
        } catch(e:Dynamic) {
            log_error("Error parsing method call", Std.string(e));
        }

        // 5. Variable Substitution logic
        var regex_token = ~/(@%.*?%%)|(%.*?%%)|(@?[a-zA-Z_]\w*)/;
        var out_buf = new StringBuf();
        var i = 0;
        var L = s_expr.length;
        var in_sq = false;
        var in_dq = false;
        var esc = false;

        while (i < L) {
            var ch = s_expr.charAt(i);
            if (esc) { out_buf.add(ch); esc = false; i++; continue; }
            if (ch == '\\') { out_buf.add(ch); esc = true; i++; continue; }
            if (ch == "'" && !in_dq) { in_sq = !in_sq; out_buf.add(ch); i++; continue; }
            if (ch == '"' && !in_sq) { in_dq = !in_dq; out_buf.add(ch); i++; continue; }

            if (!in_sq && !in_dq) {
                if (regex_token.matchSub(s_expr, i)) {
                    var pos = regex_token.matchedPos();
                    if (pos.pos == i) {
                        var token = regex_token.matched(0);
                        if (token == "and" || token == "or" || token == "not" || token == "True" || token == "False") {
                            out_buf.add(token);
                            i += pos.len;
                            continue;
                        }

                        var val:Dynamic = 0;
                        if (StringTools.startsWith(token, "%") && StringTools.endsWith(token, "%%")) {
                            var inner = token.substring(1, token.length - 2);
                            var vname = process_complex_name(StringTools.trim(inner), local_env);
                            val = (local_env.exists(vname)) ? local_env[vname] : (globals_env.exists(vname) ? globals_env[vname] : 0);
                        } else if (StringTools.startsWith(token, "@%") && StringTools.endsWith(token, "%%")) {
                             var inner = token.substring(2, token.length - 2);
                             var vname = process_complex_name(StringTools.trim(inner), local_env);
                             val = globals_env.exists(vname) ? globals_env[vname] : 0;
                        } else if (StringTools.startsWith(token, "@")) {
                            var vname = token.substring(1);
                            val = globals_env.exists(vname) ? globals_env[vname] : 0;
                        } else {
                            // Order check: Local first, then Global
                            if (local_env.exists(token)) val = local_env[token];
                            else if (globals_env.exists(token)) val = globals_env[token];
                            else {
                                // Keep original token if not found (allows HScript math/logic to work)
                                out_buf.add(token);
                                i += pos.len;
                                continue;
                            }
                        }

                        if (Std.isOfType(val, String)) out_buf.add(Json.stringify(val));
                        else out_buf.add(Std.string(val));
                        
                        i += pos.len;
                        continue;
                    }
                }
            }
            out_buf.add(ch);
            i++;
        }
        
        s_expr = out_buf.toString();

        // FINAL SAFE EVALUATION
        try {
            s_expr = StringTools.replace(s_expr, " and ", " && ");
            s_expr = StringTools.replace(s_expr, " or ", " || ");
            s_expr = StringTools.replace(s_expr, " not ", " ! ");
            s_expr = StringTools.replace(s_expr, "True", "true");
            s_expr = StringTools.replace(s_expr, "False", "false");

            var ast = parser.parseString(s_expr);
            return interp.execute(ast);
        } catch (e:Dynamic) {
           return s_expr;
        }
    }
    // ---------------------------
    // BLOCK EXECUTION
    // ---------------------------
    static function execute_block(lines:Array<String>, local_env:Map<String, Dynamic>):Dynamic {
        var i = 0;
        while (i < lines.length) {
            var raw_line = lines[i];
            var line = StringTools.trim(remove_inline_comment(raw_line));

            if (line.length > 0 && !StringTools.startsWith(line, "//")) {
                set_context(line);
            }

            if (line.length == 0 || StringTools.startsWith(line, "//")) {
                i++; continue;
            }

            if (line == 'break') return {'rt_break': true};
            if (line == 'continue') return {'rt_continue': true};

            // WHILE
            var while_reg = ~/while\s*\?\s*(.*?)\s*\{/;
            if (while_reg.match(line)) {
                var inner_lines:Array<String> = [];
                var depth = 1;
                i++;
                while (i < lines.length && depth > 0) {
                    var next_line_raw = lines[i];
                    var next_line = remove_inline_comment(next_line_raw);
                    depth += count_occurrences(next_line, "{") - count_occurrences(next_line, "}");
                    
                    if (depth <= 0) {
                        var stripped = StringTools.trim(next_line);
                        if (stripped != "}" && next_line.indexOf("}") != -1) {
                            var idx = next_line.lastIndexOf("}");
                            var part = StringTools.trim(next_line.substring(0, idx));
                            if (part.length > 0) inner_lines.push(part);
                        }
                        i++;
                        break;
                    } else {
                        inner_lines.push(StringTools.trim(next_line));
                        i++;
                    }
                }
                var res = execute_while_loop(while_reg.matched(1), inner_lines, local_env);
                if (Std.isOfType(res,  haxe.ds.StringMap) || (Reflect.isObject(res) && Reflect.hasField(res, "rt_return"))) return res;
                continue;
            }

            // CONDITIONAL
            var cond_reg = ~/([@]?[a-zA-Z_]\w*)\s+is\s*\?\s*(.*?)\s*\?\?\s*(.*?)\s*\{/;
            if (cond_reg.match(line)) {
                 var inner_lines:Array<String> = [];
                 var depth = 1;
                 i++;
                 while (i < lines.length && depth > 0) {
                     var next_line_raw = lines[i];
                     var next_line = remove_inline_comment(next_line_raw);
                     depth += count_occurrences(next_line, "{") - count_occurrences(next_line, "}");
                     
                     if (depth <= 0) {
                         var stripped = StringTools.trim(next_line);
                         if (stripped != "}" && next_line.indexOf("}") != -1) {
                             var idx = next_line.lastIndexOf("}");
                             var part = StringTools.trim(next_line.substring(0, idx));
                             if (part.length > 0) inner_lines.push(part);
                         }
                         i++;
                         break;
                     } else {
                         inner_lines.push(StringTools.trim(next_line));
                         i++;
                     }
                 }
                 var res = execute_conditional_block(line, inner_lines, local_env);
                 if (Reflect.isObject(res) && (Reflect.hasField(res, "rt_return") || Reflect.hasField(res, "rt_break") || Reflect.hasField(res, "rt_continue"))) {
                     return res;
                 }
                 continue;
            }

            var result = execute_line(line, local_env);
            if (Reflect.isObject(result) && Reflect.hasField(result, "rt_return")) return result;

            i++;
        }
        return null;
    }

    static function count_occurrences(s:String, sub:String):Int {
        return s.split(sub).length - 1;
    }

    static function execute_while_loop(condition_expr:String, body_lines:Array<String>, local_env:Map<String, Dynamic>):Dynamic {
        while (true) {
            try {
                var cond_val = eval_expr(condition_expr, local_env);
                if (!is_truthy(cond_val)) break;
                
                var res = execute_block(body_lines, local_env);
                if (Reflect.isObject(res)) {
                    if (Reflect.hasField(res, "rt_return")) return res;
                    if (Reflect.hasField(res, "rt_break")) break;
                    if (Reflect.hasField(res, "rt_continue")) continue;
                }
            } catch (e:Dynamic) {
                log_error("Error inside while-loop", Std.string(e));
                break;
            }
        }
        return null;
    }

    static function execute_conditional_block(header:String, body_lines:Array<String>, local_env:Map<String, Dynamic> = null):Dynamic {
        try {
            var m = ~/([@]?[a-zA-Z_]\w*)\s+is\s*\?\s*(.*?)\s*\?\?\s*(.*?)\s*\{/;
            if (!m.match(header)) return null;

            var var_token = StringTools.trim(m.matched(1));
            var expr1 = StringTools.trim(m.matched(2));
            var expr2 = StringTools.trim(m.matched(3));

            var val1 = eval_expr(expr1, local_env);
            var val2 = eval_expr(expr2, local_env);
            var assign_val = is_truthy(val1) ? val1 : val2;
            var should_run_body = (!is_truthy(val1)) && is_truthy(val2);

            if (should_run_body) {
                var res = execute_block(body_lines, local_env);
                if (Reflect.isObject(res) && (Reflect.hasField(res, "rt_return") || Reflect.hasField(res, "rt_break") || Reflect.hasField(res, "rt_continue")))
                    return res;
            }

            if (local_env != null) {
                if (StringTools.startsWith(var_token, "@")) globals_env[var_token.substring(1)] = assign_val;
                else local_env[var_token] = assign_val;
            } else {
                globals_env[StringTools.replace(var_token, "@", "")] = assign_val;
            }
            return assign_val;

        } catch (e:Dynamic) {
            log_error("Error in conditional block logic", Std.string(e));
            return 0;
        }
    }

    static function is_truthy(v:Dynamic):Bool {
        if (v == null) return false;
        if (Std.isOfType(v, Bool)) return v;
        if (Std.isOfType(v, Int) || Std.isOfType(v, Float)) return v != 0;
        if (Std.isOfType(v, String)) return (cast v:String).length > 0;
        return true;
    }

    static function execute_method(name:String, args:Array<Dynamic>):Dynamic {
        if (!methods.exists(name)) {
            log_error('Method $name not defined.');
            return null;
        }
        try {
            var method = methods[name];
            var local_env:Map<String, Dynamic> = [];
            var params:Array<String> = method.params;
            for (i in 0...params.length) {
                if (i < args.length) local_env[params[i]] = args[i];
            }
            
            var res = execute_block(method.body, local_env);
            if (Reflect.isObject(res) && Reflect.hasField(res, "rt_return")) return Reflect.field(res, "rt_return");
            return 0;
        } catch (e:Dynamic) {
            log_error('Crash inside method $name', Std.string(e));
            return 0;
        }
    }

    // ---------------------------
    // EXECUTION
    // ---------------------------
    static function execute_line(line:String, local_env:Map<String, Dynamic> = null):Dynamic {
        try {
            line = StringTools.trim(remove_inline_comment(line));
            if (line.length == 0 || StringTools.startsWith(line, "//")) return null;

            // Standalone system calls
            var bracket_call = find_bracket_call(line);
            if (bracket_call != null) {
                if (bracket_call.s_idx == 0 && bracket_call.end_idx == line.length && SYSTEM_FUNCS.exists(bracket_call.fname)) {
                    return call_system_function(bracket_call.fname, bracket_call.content, local_env);
                }
            }

            // Complex Var Assignment ($...$$)
            var dollar_reg = ~/(@?\$.*?\$\$)\s*is\s*(.*)/;
            if (dollar_reg.match(line)) {
                var var_token = StringTools.trim(dollar_reg.matched(1));
                var expr = StringTools.trim(dollar_reg.matched(2));
                var val = eval_expr(expr, local_env);
                
                var inner = StringTools.trim(StringTools.replace(StringTools.replace(var_token, "@", ""), "$", ""));
                var v_name = process_complex_name(inner, local_env);
                
                if (StringTools.startsWith(var_token, "@")) globals_env[v_name] = val;
                else if (local_env != null) local_env[v_name] = val;
                else globals_env[v_name] = val;
                
                return val;
            }

            if (line.indexOf(" is ") != -1) {
                var parts = line.split(" is ");
                var var_name = StringTools.trim(parts[0]);
                var expr = StringTools.trim(parts.slice(1).join(" is ")); // Join back in case 'is' appears later

                // Method Definition
                if (expr.indexOf("mfunc") != -1) {
                    var clean_expr = StringTools.trim(expr.split("{")[0]);
                    var mparts = clean_expr.split("(");
                    var rest = mparts[1];
                    var raw_params = rest.split(")")[0].split(",");
                    var params = [for (p in raw_params) StringTools.trim(p)];
                    if (params.length == 1 && params[0] == "") params = []; // handle empty args
                    
                    methods[var_name] = {params: params, body: []};
                    return {method_def: var_name};
                }

                // Normal Assignment
                var val = eval_expr(expr, local_env);
                if (var_name == "return") return { "rt_return": val };

                if (local_env != null) {
                    if (StringTools.startsWith(var_name, "@")) globals_env[var_name.substring(1)] = val;
                    else local_env[var_name] = val;
                } else {
                    globals_env[StringTools.replace(var_name, "@", "")] = val;
                }
                return val;
            }
            return null;

        } catch (e:Dynamic) {
            log_error("Failed to execute line", Std.string(e));
            return null;
        }
    }

    // ---------------------------
    // PARSER
    // ---------------------------
    static function parse_program(lines:Array<String>):Void {
        var i = 0;
        while (i < lines.length) {
            var raw_line = lines[i];
            var line = StringTools.rtrim(remove_inline_comment(raw_line));
            
            if (line.length > 0) set_context(line);
            i++;
            if (StringTools.trim(line).length == 0) continue;

            if (line.indexOf(" is ") != -1 && line.indexOf("mfunc") != -1) {
                var res:Dynamic = execute_line(line);
                if (Reflect.isObject(res) && Reflect.hasField(res, "method_def")) {
                    var m_name = Reflect.field(res, "method_def");
                    var body:Array<String> = [];
                    var h_rest = line.substring(line.indexOf("mfunc"));
                    var depth = count_occurrences(h_rest, "{") - count_occurrences(h_rest, "}");
                    
                    while (i < lines.length && depth > 0) {
                        var nxt_raw = lines[i];
                        i++;
                        var nxt = StringTools.rtrim(remove_inline_comment(nxt_raw));
                        depth += count_occurrences(nxt, "{") - count_occurrences(nxt, "}");
                        
                        if (depth <= 0 && nxt.indexOf("}") != -1) {
                            var idx = nxt.lastIndexOf("}");
                            var part = StringTools.trim(nxt.substring(0, idx));
                            if (part.length > 0) body.push(part);
                            break;
                        } else {
                            body.push(StringTools.trim(nxt));
                        }
                    }
                    var m = methods[m_name];
                    m.body = body;
                    methods[m_name] = m;
                }
                continue;
            }

            var while_reg = ~/while\s*\?\s*(.*?)\s*\{/;
            if (while_reg.match(StringTools.trim(line))) {
                var body_lines:Array<String> = [];
                var depth = 1;
                while (i < lines.length && depth > 0) {
                    var nxt_raw = lines[i];
                    i++;
                    var nxt = StringTools.rtrim(remove_inline_comment(nxt_raw));
                    depth += count_occurrences(nxt, "{") - count_occurrences(nxt, "}");
                    if (depth == 0) {
                         if (nxt.indexOf("}") != -1) {
                             var idx = nxt.lastIndexOf("}");
                             var part = StringTools.trim(nxt.substring(0, idx));
                             if (part.length > 0) body_lines.push(part);
                         }
                         break;
                    } else {
                        body_lines.push(StringTools.trim(nxt));
                    }
                }
                execute_while_loop(while_reg.matched(1), body_lines, null);
                continue;
            }

            var cond_reg = ~/([@]?[a-zA-Z_]\w*)\s+is\s*\?\s*(.*?)\s*\?\?\s*(.*?)\s*\{/;
            if (cond_reg.match(StringTools.trim(line))) {
                var body_lines:Array<String> = [];
                var depth = 1;
                while (i < lines.length && depth > 0) {
                    var nxt_raw = lines[i];
                    i++;
                    var nxt = StringTools.rtrim(remove_inline_comment(nxt_raw));
                    depth += count_occurrences(nxt, "{") - count_occurrences(nxt, "}");
                    if (depth == 0) {
                        if (nxt.indexOf("}") != -1) {
                            var idx = nxt.lastIndexOf("}");
                            var part = StringTools.trim(nxt.substring(0, idx));
                            if (part.length > 0) body_lines.push(part);
                        }
                        break;
                    } else {
                        body_lines.push(StringTools.trim(nxt));
                    }
                }
                execute_conditional_block(StringTools.trim(line), body_lines, null);
                continue;
            }

            execute_line(StringTools.trim(line));
        }
    }

    // ---------------------------
    // ENTRY POINT
    // ---------------------------
    static function main() {
        // Init Hscript
        parser = new Parser();
        interp = new Interp();

        var args = Sys.args();
        var filename = "";
        
        var i = 0;
        while(i < args.length) {
            if ((args[i] == "-e" || args[i] == "--execute") && i + 1 < args.length) {
                filename = args[i+1];
                break;
            }
            i++;
        }

        if (filename == "") {
            Sys.println("Error: No input file provided. Use -e <file.epi>");
            //filename = "index.epi";
            Sys.exit(1);
        }

        if (!FileSystem.exists(filename)) {
            Sys.println('Error: File not found: $filename');
            Sys.exit(1);
        }

        try {
            var content = File.getContent(filename);
            var lines = content.split("\n");
            // normalize line endings
            lines = [for (l in lines) StringTools.replace(l, "\r", "")];
            parse_program(lines);
        } catch (e:Dynamic) {
            log_error("Fatal Interpreter Error", Std.string(e));
            Sys.exit(1);
        }
    }
}
