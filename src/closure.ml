open Syntax

let pr = "
        Value *tenv = malloc((len + 1) * sizeof(Value));
        memcpy (tenv + 1, env, len * sizeof(Value));
        *tenv = n;\n"

exception Error of string

type closure
  = CloVar  of int * expr_t
  | CloNum  of int * expr_t
  | Closure of int list * closure * expr_t
  | CloApp  of closure * closure * expr_t
  | CloGVar of string * expr_t
  | CloCase of (closure * closure) list * expr_t
  | CloList of closure list * expr_t

let builtin_funs =
  ["suml"; "difl"; "timl"; "divl"; "unil"; "indl"; "conl"; "head"; "tail"]

let rec free e s =
  match e with
    TyVar _
  | TyNum _ -> []
  | TyApp(l, r, _) -> free l s @ free r s
  | TyIndVar (n, _) when n >= s -> [n]
  | TyIndVar _ -> []
  | TyLambda(_, body, _) -> free body (s + 1)
  | TyCase (c, _) -> let _, exps = List.split c in
    List.fold_left (@) [] (List.map (fun x -> free x s) exps)
  | TyList (l, _) -> List.fold_left (@) [] (List.map (fun x -> free x s) l)

let rec deB e (v, n) =
  match e with
    TyVar (v2, t) when v = v2 -> TyIndVar (n, t)
  | TyVar _ as v              -> v
  | TyLambda (x, body, t)     -> TyLambda ("", deB (deB body (x, 1)) (v, n + 1) , t)
  | TyApp (l, r, t)           -> TyApp (deB l (v, n), deB r (v, n), t)
  | TyNum _ as n              -> n
  | TyIndVar _ as n           -> n
  | TyCase (c, t)             -> TyCase (Utils.snd_map (fun x -> deB x (v, n + 1)) c, t)
  | TyList (l, t)             -> let nl = List.map (fun x -> deB x (v, n)) l in
    TyList (nl, t)

let rec to_closure expr =
  match expr with
    TyNum (n, t)         -> CloNum (n, t)
  | TyVar (n, t) when
      (List.mem n builtin_funs)
                         -> CloGVar (n, t)
  | TyVar (n, t)         -> CloGVar ("_" ^ n, t)
  | TyIndVar(n, t)       -> CloVar (n, t)
  | TyLambda(_, b, t)   -> Closure (free expr 1, to_closure b, t)
  | TyApp (l, r, t)     -> CloApp (to_closure l, to_closure r, t)
  | TyCase (c, t)       -> let p, e = List.split c in
    let cp = List.map to_closure p in
    let ce = List.map to_closure e in
    CloCase (List.combine cp ce, t)
  | TyList (l, t)       -> CloList (List.map to_closure l, t)

let rec closure_to_c clo nlam env ctx =
  match clo with
    CloNum (n, _) -> Printf.sprintf "make_int(%d)" n, "", "", nlam, env
  | CloVar (n, _) ->
    begin
      (* If the index is not one, the variable is in the closure's context. *)
      match n with
        1 -> "n"
      | n -> Printf.sprintf "(*(env + %d))" (n - 2)
    end, "", "", nlam, env
  | CloApp (f, arg, t) ->
    let s1, nf, p1, nlam, nv = closure_to_c f nlam env ctx in
    let n = Printf.sprintf "l%d" nlam in
    let s2, na, p2, nlam, v =
      match t with
        TFun (_, _) -> closure_to_c arg (nlam + 1)  (n ^ ".clo.env") ctx
      | _ -> closure_to_c arg (nlam + 1) env ctx
    in
    begin
      match f with
        CloGVar _ ->
        n, nf ^ na, p1 ^  p2 ^
                    (Printf.sprintf "Value %s = %s.clo.lam(tenv, %s, len + 1);\n"
                       n s1 s2), nlam, v
      | _ -> n, nf ^ na, p1 ^  p2 ^
                         (Printf.sprintf "Value %s = %s.clo.lam(%s, %s, len + 1);\n"
                            n s1 nv s2), nlam, v
    end
  | CloGVar (v, _) ->
    begin
      match Char.code (String.get v 1) with
        c when c >= (Char.code 'a') -> v
      | _ ->
        match List.assoc (String.sub v 1 ((String.length v) - 1)) ctx with
          Forall ([], TOth v2) -> "make_" ^ v2 ^ "(" ^ (String.uppercase_ascii v) ^ ")"
        | _                   -> raise (Invalid_argument "shouldn't happened")
    end, "", "", nlam, env
  | Closure (_, body, _) ->
    let n = Printf.sprintf "l%d" nlam in
    let cbody, nf, c, nnlam, _ = closure_to_c body (nlam + 1) "tenv" ctx in
    n, nf ^ (Printf.sprintf "Value __lam%d(Value *env, Value n, int len) {
     %s%sfree(tenv);\nreturn(%s);\n}" nlam pr c cbody),
    (Printf.sprintf "Value %s = make_closure (__lam%d, %s, len + 1);\n" n nlam env),
    nnlam, env
  | CloCase (c, t) ->
    let type_to_c t =
      match t with
        TFun(TOth v, _) -> "._" ^ v
      | _      -> raise (Error "invalid pattern matching")
    in
    let case_to_c p nlam =
      match p with
        []           -> "", "", "", nlam, []
      | (f, s) :: tl ->
        let nbody, nf, p2, nlam, _ = closure_to_c s (nlam + 1) env ctx in
        let p3, nlam, nf2, p4 =
          match f with
          CloGVar (v, _) when (Char.code (String.get v 1) >= Char.code 'a') ->
          Printf.sprintf "else{\n%s\nreturn %s;\n}" p2 nbody, nlam, "", ""
        | _ ->
          let np, nf2, p4, nlam, _ = closure_to_c f (nlam) env ctx in
          (Printf.sprintf "if ((%s%s) == ((*tenv)%s)) {\n%s\nreturn %s;\n}\n"
             np (type_to_c t) (type_to_c t) p2 nbody), nlam + 1, nf2, p4
        in
        p3, nf ^ nf2, p4, nlam, tl
    in
    let rec cases_to_c n nf p nlam l =
      match l with
        [] -> n, nf, p, nlam, env
      | l  ->
        let n2, nf2, p2, nlam, tl = case_to_c l nlam in
        cases_to_c (n ^ n2) (nf ^ nf2) (p ^ p2) nlam tl
    in
    let b, nf, p, nlam, _ = cases_to_c "" "" "" nlam c in
    let f =
      Printf.sprintf
        "Value __lam%d(Value *env, Value n, int len) {
        %s
        %s
}" nlam pr b
    in
    Printf.sprintf "make_closure(__lam%d,tenv, len + 1)" nlam, nf ^ f, p, nlam + 1, env
  | CloList (clo, _) ->
    let lp = Printf.sprintf "l%d" nlam in
    let rec l_to_c nlam pos =
      function
        []       ->  "", "", nlam
      | hd :: tl -> let b, f, p, nlam, _ = closure_to_c hd nlam env ctx in
        let nf, np, nlam = l_to_c nlam (pos + 1) tl in
        let pl = Printf.sprintf "*(%s + %d) = %s;\n" lp pos b in
        f ^ nf, p ^ np ^ pl, nlam
    in
    let f, p, nlam = l_to_c nlam 0 clo in
    (Printf.sprintf "make_list(%s, %d)" lp (List.length clo)), f,
    (Printf.sprintf "Value *%s = malloc (%d * sizeof(Value));\n" lp
       (List.length clo)) ^ p, nlam + 1, env


let rec decls_to_c decls funs body nlam ctx =
  match decls with
    [] ->
    let rec range = function -1 -> [] | n -> n :: range (n - 1) in
    let s = List.fold_left (fun x y -> x ^ (Printf.sprintf "Value l%d;\n" y))
        "" (range (nlam - 1)) in
    "#include \"core.h\"\n#include <stdlib.h>\n#include <stdio.h>\nValue suml;\nValue difl;
Value divl;\nValue timl;\nValue conl;\nValue unil;\nValue indl;\n" ^ s ^
    funs ^
    "\nint main (int argc, char* argv[]) {
        if (argc == 1){
            puts(\"Error: the program has to be called with an argument.\");
            exit(1);
        }
        int num;
        if (sscanf(argv[1], \"%d\", &num) != 1) {
            puts(\"Error: the input should be a number.\");
            exit (1);
        }
        Value *tenv = malloc(sizeof(Value));
        Value n = make_int(num);
        *tenv = n;
        int len = 0;
        difl = make_closure(dif, NULL, 0);
        divl = make_closure(dv, NULL, 0);
        timl = make_closure(tim, NULL, 0);
        suml = make_closure(sum, NULL, 0);
        unil = make_closure(octo_union, NULL, 0);
        conl = make_closure(cons, NULL, 0);
        indl = make_closure(ind, NULL, 0);\n" ^
    body ^
    "\n}\n"
  | hd :: tl ->
    match hd with
      TyDecl (v, b, _) when v = "main"->
      let nbody, nf, b, nlam, _ = closure_to_c (to_closure (deB b ("", 1)))
          nlam "tenv" ctx
      in
      decls_to_c tl (funs ^ nf) (body ^ b ^ "\nfree (tenv);\nprintf(\"%d\\n\"," ^
                                 nbody ^ ".clo.lam(NULL, n, 0)._int);\n return 0;") nlam ctx
    | TyDecl (v, b, _) ->
      let fn, nf, b, nlam, _ = closure_to_c (to_closure (deB b ("", 1)))
          nlam "tenv" ctx
      in
      let f = Printf.sprintf "Value _%s;\n" v in
      decls_to_c tl (funs ^ f ^ nf ) (body ^ b ^ (Printf.sprintf "_%s = %s;\n" v fn)) nlam ctx