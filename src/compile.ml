let read_from_file f =
  let ic = open_in f in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.unsafe_to_string s

let compile str =
  let tokens, _ = Lexer.lexer str 0 1 0 0  in
  let decls     = Parser.parse_tops tokens in
  let rec def_ctx decls context nvar =
    match decls with
      [] -> context
    | Syntax.Decl(v, body) :: tl ->
      let s, t, nvar = Types.infer body context nvar in
      let n_ctx      = (Types.subst_context s context) @ [v, Types.gen context t] in
      def_ctx tl n_ctx nvar
  in
  def_ctx decls [] 0