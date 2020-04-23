open Syntax
open Closure
open Printf

let read_from_file f =
  let ic = open_in f in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.unsafe_to_string s

let rec def_ctx decls context types nd nlam texpr tc ist mn tp =
  match decls with
    [] -> context, types, nd, texpr, tc, ist, mn, tp, nlam
  | Decl (v1, b1) :: And (Decl (v2, b2)) :: tl ->
    let tmp_ctx =
      context @ [v1, Forall([], TVar nlam); v2, Forall([], TVar (nlam + 1))] in
    let s, t, _, e = Types.infer b1 tmp_ctx (nlam + 2) in
    let n_ctx  = (Types.subst_context s context) @ [v1, Types.gen context t;
                                                    v2, Forall([], TVar (nlam + 1))] in
    let s, t2, _, e2 = Types.infer b2 n_ctx (nlam + 3) in
    let n_ctx  = (Types.subst_context s n_ctx) @ [v2, Types.gen context t2] in
    def_ctx tl n_ctx types nd (nlam + 4)
      (texpr @ [TyDecl (v1, e, t); TyDecl (v2, e2, t2)]) tc ist mn (tp ^ (sprintf "Value _%s;" v2))
  | Decl(v, body) :: tl ->
    let tmp_ctx    = context @ [v, Forall([], TVar (nlam))] in
    let s, t, _, e = Types.infer body tmp_ctx (nlam + 1)    in
    let n_ctx  =
      match v with
        "main" ->
        (* The main function should be of type string -> string *)
        let s2 = Types.unify t (TFun(TList (TOth "char"), TOth "float")) in
        (Types.subst_context (Types.compose_subst s s2) context) @
        [v, Forall([], TFun(TList (TOth "char"), TOth "float"))]
      | _ ->
        (Types.subst_context s context) @ [v, Types.gen context t]
    in
    def_ctx tl n_ctx types nd (nlam + 2) (texpr @ [TyDecl (v, e, t)]) tc ist mn tp
  | TDef t :: tl ->
    let v =
      match snd (List.hd t) with
        Forall (_, t) -> Utils.get_t_n t
    in
    let n, _ = List.split t in
    let s    = "  enum {" ^
               (List.fold_left (fun x y -> x ^ ", __" ^ y)
                  ("DUMB" ^ (string_of_int nlam))
                  n ^ "} _" ^ v ^ ";") in
    let rec com_t l s1 s2 s3 =
      match l with
        [] -> s1, s2, s3
      | (n, Forall(_, t)) :: tl ->
        let n1, n2, n3 =
          match t with
            TOth _ ->
            Printf.sprintf
              "Value make_%s() {
          Value n;
          n.t = %s;
          n._%s = __%s;
          n.has_cell = 0;
          return (n);
}\n" n (String.uppercase_ascii v) v n,
            Printf.sprintf "_%s = make_%s();\n" n n,
            Printf.sprintf "Value _%s;\n" n
          | _ ->
            Printf.sprintf
              "Value make_%s(Value *env, Value cell, int len) {
          Value n;
          n.t = %s;
          n._%s = __%s;
          n.cell = malloc (sizeof(Value));
          *(n.cell) = cell;
          n.has_cell = 1;
          return (n);
}\n" n (String.uppercase_ascii v) v n,
            Printf.sprintf "_%s = make_closure(make_%s, NULL, 0);\n" n n,
            Printf.sprintf "Value _%s;\n" n
        in
        com_t tl (s1 ^ n1) (s2 ^ n2) (s3 ^ n3)
      in
let fn, m, t' = com_t t "" "" "" in
      let ntc       = ",\n  " ^ (String.uppercase_ascii v) in
      let nin       = Printf.sprintf
          "case %s :
      if (l1._%s != l2._%s)
        return (make_int(0));
      else if (l1.has_cell)
          return(intern_eq(*(l1.cell), *(l2.cell)));
    break;"
          (String.uppercase_ascii v) v v
      in
      def_ctx tl (context @ t) (types ^ s) (nd ^ fn) (nlam + 1)
        texpr (tc ^ ntc) (ist ^ nin) (mn ^ m) (tp ^ t')
  | _ -> raise Not_found

let rec compile_module m nlam ctx c1 c2 c3 c4 c5 c6 =

  match m with
    []       -> c1, c2, c3, c4, c5, c6, nlam, ctx
  | hd :: tl ->
    let s =
      read_from_file ("lib/" ^ (String.lowercase_ascii hd) ^ ".oc") in
    let t, _ = Lexer.lexer s 0 0 in
    let t, _ = List.split t in
    let p, _ = Parser.parse_tops t in
    let rec compile_funs d fs b n =
      match d with
        [] -> fs, b, n
      | TyDecl (v, bd, _) :: tl ->
        let fn, nf, nb, n, _ =
          closure_to_c (to_closure (deB bd ("", 1))) n "tenv" in
        let f = sprintf "Value _%s;\n" v in
        compile_funs tl (fs ^ f ^ nf) (b ^ nb ^ (sprintf "_%s = %s;\n" v fn)) n
    in

    let c, t, n, e, lt, i, m, tp, nlam = def_ctx p ctx "" "" nlam [] "" "" "" "" in
    let f, b, nlam = compile_funs e tp m nlam in
    compile_module tl nlam (ctx @ c) (c1 ^ tp ^ f) (c2 ^ m ^ b) (c3 ^ lt)
      (c4 ^ t) (c5 ^ i) (c6 ^ n)

let compile f =
  let s    = read_from_file f    in
  let t, _ = Lexer.lexer s 0 0   in
  let t, _ = List.split t        in
  let f, m = Parser.parse_tops t in
  let c1, c2, c3, c4, c5, c6, nlam, ctx =
    compile_module ("stdlib" :: m) 0 Types.initial_ctx "" "" "" "" "" "" in
  let _, t, n, e, lt, i, m, tp, nlam =
    def_ctx f ctx "" "" nlam [] "" "" "" "" in
  let oc = open_out "out.c"      in
  fprintf oc "%s\n" (decls_to_c e (c1 ^ tp) (c2 ^ m) nlam);
  close_out oc;
  let oc = open_out "core.h"     in
  Core.core oc (c3 ^ lt) (c4 ^ t) (c5 ^ i) (c6 ^ n)
