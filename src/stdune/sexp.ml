include Usexp

module type Combinators = sig
  type 'a t
  val unit       : unit                      t
  val string     : string                    t
  val int        : int                       t
  val float      : float                     t
  val bool       : bool                      t
  val pair       : 'a t -> 'b t -> ('a * 'b) t
  val triple     : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
  val list       : 'a t -> 'a list           t
  val array      : 'a t -> 'a array          t
  val option     : 'a t -> 'a option         t
  val string_set : String.Set.t              t
  val string_map : 'a t -> 'a String.Map.t   t
  val string_hashtbl : 'a t -> (string, 'a) Hashtbl.t t
end

module To_sexp = struct
  type nonrec 'a t = 'a -> t
  let unit () = List []
  let string = Usexp.atom_or_quoted_string
  let int n = Atom (Atom.of_int n)
  let float f = Atom (Atom.of_float f)
  let bool b = Atom (Atom.of_bool b)
  let pair fa fb (a, b) = List [fa a; fb b]
  let triple fa fb fc (a, b, c) = List [fa a; fb b; fc c]
  let list f l = List (List.map l ~f)
  let array f a = list f (Array.to_list a)
  let option f = function
    | None -> List []
    | Some x -> List [f x]
  let string_set set = list atom (String.Set.to_list set)
  let string_map f map = list (pair atom f) (String.Map.to_list map)
  let record l =
    List (List.map l ~f:(fun (n, v) -> List [Atom(Atom.of_string n); v]))
  let string_hashtbl f h =
    string_map f
      (Hashtbl.foldi h ~init:String.Map.empty ~f:(fun key data acc ->
         String.Map.add acc key data))

  type field = string * Usexp.t option

  let field name f ?(equal=(=)) ?default v =
    match default with
    | None -> (name, Some (f v))
    | Some d ->
      if equal d v then
        (name, None)
      else
        (name, Some (f v))
  let field_o name f v = (name, Option.map ~f v)

  let record_fields (l : field list) =
    List (List.filter_map l ~f:(fun (k, v) ->
      Option.map v ~f:(fun v -> List[Atom (Atom.of_string k); v])))

  let unknown _ = unsafe_atom_of_string "<unknown>"
end

module Of_sexp = struct
  type ast = Ast.t =
    | Atom of Loc.t * Atom.t
    | Quoted_string of Loc.t * string
    | Template of Template.t
    | List of Loc.t * ast list

  type hint =
    { on: string
    ; candidates: string list
    }

  exception Of_sexp of Loc.t * string * hint option

  let of_sexp_error ?hint loc msg =
    raise (Of_sexp (loc, msg, hint))
  let of_sexp_errorf ?hint loc fmt =
    Printf.ksprintf (fun msg -> of_sexp_error loc ?hint msg) fmt
  let no_templates ?hint loc fmt =
    Printf.ksprintf (fun msg ->
      of_sexp_error loc ?hint ("No variables allowed " ^ msg)) fmt

  type unparsed_field =
    { values : Ast.t list
    ; entry  : Ast.t
    ; prev   : unparsed_field option (* Previous occurrence of this field *)
    }

  module Name = struct
    type t = string
    let compare a b =
      let alen = String.length a and blen = String.length b in
      match Int.compare alen blen with
      | Eq -> String.compare a b
      | ne -> ne
  end

  module Name_map = Map.Make(Name)

  type values = Ast.t list
  type fields =
    { unparsed : unparsed_field Name_map.t
    ; known    : string list
    }

  (* Arguments are:

     - the location of the whole list
     - the first atom when parsing a constructor or a field
     - the universal map holding the user context
  *)
  type 'kind context =
    | Values : Loc.t * string option * Univ_map.t -> values context
    | Fields : Loc.t * string option * Univ_map.t -> fields context

  type ('a, 'kind) parser =  'kind context -> 'kind -> 'a * 'kind

  type 'a t             = ('a, values) parser
  type 'a fields_parser = ('a, fields) parser

  let return x _ctx state = (x, state)
  let (>>=) t f ctx state =
    let x, state = t ctx state in
    f x ctx state
  let (>>|) t f ctx state =
    let x, state = t ctx state in
    (f x, state)
  let (>>>) a b ctx state =
    let (), state = a ctx state in
    b ctx state
  let map t ~f = t >>| f

  let get_user_context : type k. k context -> Univ_map.t = function
    | Values (_, _, uc) -> uc
    | Fields (_, _, uc) -> uc

  let get key ctx state = (Univ_map.find (get_user_context ctx) key, state)
  let get_all ctx state = (get_user_context ctx, state)

  let set : type a b k. a Univ_map.Key.t -> a -> (b, k) parser -> (b, k) parser
    = fun key v t ctx state ->
      match ctx with
      | Values (loc, cstr, uc) ->
        t (Values (loc, cstr, Univ_map.add uc key v)) state
      | Fields (loc, cstr, uc) ->
        t (Fields (loc, cstr, Univ_map.add uc key v)) state

  let set_many : type a k. Univ_map.t -> (a, k) parser -> (a, k) parser
    = fun map t ctx state ->
      match ctx with
      | Values (loc, cstr, uc) ->
        t (Values (loc, cstr, Univ_map.superpose uc map)) state
      | Fields (loc, cstr, uc) ->
        t (Fields (loc, cstr, Univ_map.superpose uc map)) state

  let loc : type k. k context -> k -> Loc.t * k = fun ctx state ->
    match ctx with
    | Values (loc, _, _) -> (loc, state)
    | Fields (loc, _, _) -> (loc, state)

  let eos : type k. k context -> k -> bool * k = fun ctx state ->
    match ctx with
    | Values _ -> (state = [], state)
    | Fields _ -> (Name_map.is_empty state.unparsed, state)

  let repeat : 'a t -> 'a list t =
    let rec loop t acc ctx l =
      match l with
      | [] -> (List.rev acc, [])
      | _ ->
        let x, l = t ctx l in
        loop t (x :: acc) ctx l
    in
    fun t ctx state -> loop t [] ctx state

  let result : type a k. k context -> a * k -> a =
    fun ctx (v, state) ->
      match ctx with
      | Values (_, cstr, _) -> begin
          match state with
          | [] -> v
          | sexp :: _ ->
            match cstr with
            | None ->
              of_sexp_errorf (Ast.loc sexp) "This value is unused"
            | Some s ->
              of_sexp_errorf (Ast.loc sexp) "Too many argument for %s" s
        end
      | Fields _ -> begin
          match Name_map.choose state.unparsed with
          | None -> v
          | Some (name, { entry; _ }) ->
            let name_loc =
              match entry with
              | List (_, s :: _) -> Ast.loc s
              | _ -> assert false
            in
            of_sexp_errorf ~hint:{ on = name; candidates = state.known }
              name_loc "Unknown field %s" name
        end

  let parse t context sexp =
    let ctx = Values (Ast.loc sexp, None, context) in
    result ctx (t ctx [sexp])

  let capture ctx state =
    let f t =
      result ctx (t ctx state)
    in
    (f, [])

  let end_of_list (Values (loc, cstr, _)) =
    match cstr with
    | None ->
      let loc = { loc with start = loc.stop } in
      of_sexp_errorf loc "Premature end of list"
    | Some s ->
      of_sexp_errorf loc "Not enough arguments for %s" s
  [@@inline never]

  let next f ctx sexps =
    match sexps with
    | [] -> end_of_list ctx
    | sexp :: sexps -> (f sexp, sexps)
  [@@inline always]

  let next_with_user_context f ctx sexps =
    match sexps with
    | [] -> end_of_list ctx
    | sexp :: sexps -> (f (get_user_context ctx) sexp, sexps)
  [@@inline always]

  let peek _ctx sexps =
    match sexps with
    | [] -> (None, sexps)
    | sexp :: _ -> (Some sexp, sexps)
  [@@inline always]

  let peek_exn ctx sexps =
    match sexps with
    | [] -> end_of_list ctx
    | sexp :: _ -> (sexp, sexps)
  [@@inline always]

  let junk = next ignore

  let plain_string f =
    next (function
      | Atom (loc, A s) | Quoted_string (loc, s) -> f ~loc s
      | Template { loc ; _ } | List (loc, _) ->
        of_sexp_error loc "Atom or quoted string expected")

  let enter t =
    next_with_user_context (fun uc sexp ->
      match sexp with
      | List (loc, l) ->
        let ctx = Values (loc, None, uc) in
        result ctx (t ctx l)
      | sexp ->
        of_sexp_error (Ast.loc sexp) "List expected")

  let fix f =
    let rec p = lazy (f r)
    and r ast = (Lazy.force p) ast in
    r

  let located t ctx state1 =
    let x, state2 = t ctx state1 in
    match state1 with
    | sexp :: rest when rest == state2 -> (* common case *)
      ((Ast.loc sexp, x), state2)
    | [] ->
      let (Values (loc, _, _)) = ctx in
      (({ loc with start = loc.stop }, x), state2)
    | sexp :: rest ->
      let loc = Ast.loc sexp in
      let rec search last l =
        if l == state2 then
          (({ loc with stop = (Ast.loc last).stop }, x), state2)
        else
          match l with
          | [] ->
            let (Values (loc, _, _)) = ctx in
            (({ (Ast.loc sexp) with stop = loc.stop }, x), state2)
          | sexp :: rest ->
            search sexp rest
      in
      search sexp rest

  let raw = next (fun x -> x)

  let unit =
    next
      (function
        | List (_, []) -> ()
        | sexp -> of_sexp_error (Ast.loc sexp) "() expected")

  let basic desc f =
    next (function
      | Template { loc; _ } | List (loc, _) | Quoted_string (loc, _) ->
        of_sexp_errorf loc "%s expected" desc
      | Atom (loc, s)  ->
        match f (Atom.to_string s) with
        | Result.Error () ->
          of_sexp_errorf loc "%s expected" desc
        | Ok x -> x)

  let string = plain_string (fun ~loc:_ x -> x)
  let int =
    basic "Integer" (fun s ->
      match int_of_string s with
      | x -> Ok x
      | exception _ -> Result.Error ())

  let float =
    basic "Float" (fun s ->
      match float_of_string s with
      | x -> Ok x
      | exception _ -> Result.Error ())

  let pair a b =
    enter
      (a >>= fun a ->
       b >>= fun b ->
       return (a, b))

  let triple a b c =
    enter
      (a >>= fun a ->
       b >>= fun b ->
       c >>= fun c ->
       return (a, b, c))

  let list t = enter (repeat t)

  let array t = list t >>| Array.of_list

  let option t =
    enter
      (eos >>= function
       | true -> return None
       | false -> t >>| Option.some)

  let string_set = list string >>| String.Set.of_list
  let string_map t =
    list (pair string t) >>= fun bindings ->
    match String.Map.of_list bindings with
    | Result.Ok x -> return x
    | Error (key, _v1, _v2) ->
      loc >>= fun loc ->
      of_sexp_errorf loc "key %s present multiple times" key

  let string_hashtbl t =
    string_map t >>| fun map ->
    let tbl = Hashtbl.create (String.Map.cardinal map + 32) in
    String.Map.iteri map ~f:(Hashtbl.add tbl);
    tbl


  let find_cstr cstrs loc name ctx values =
    match List.assoc cstrs name with
    | Some t ->
      result ctx (t ctx values)
    | None ->
      of_sexp_errorf loc
        ~hint:{ on         = name
              ; candidates = List.map cstrs ~f:fst
              }
        "Unknown constructor %s" name

  let sum cstrs =
    next_with_user_context (fun uc sexp ->
      match sexp with
      | Atom (loc, A s) ->
        find_cstr cstrs loc s (Values (loc, Some s, uc)) []
      | Template { loc; _ }
      | Quoted_string (loc, _) ->
        of_sexp_error loc "Atom expected"
      | List (loc, []) ->
        of_sexp_error loc "Non-empty list expected"
      | List (loc, name :: args) ->
        match name with
        | Quoted_string (loc, _) | List (loc, _) | Template { loc; _ } ->
          of_sexp_error loc "Atom expected"
        | Atom (s_loc, A s) ->
          find_cstr cstrs s_loc s (Values (loc, Some s, uc)) args)

  let enum cstrs =
    next (function
      | Quoted_string (loc, _)
      | Template { loc; _ }
      | List (loc, _) -> of_sexp_error loc "Atom expected"
      | Atom (loc, A s) ->
        match List.assoc cstrs s with
        | Some value -> value
        | None ->
          of_sexp_errorf loc
            ~hint:{ on         = s
                  ; candidates = List.map cstrs ~f:fst
                  }
            "Unknown value %s" s)

  let bool = enum [ ("true", true); ("false", false) ]

  let consume name state =
    { unparsed = Name_map.remove state.unparsed name
    ; known    = name :: state.known
    }

  let add_known name state =
    { state with known = name :: state.known }

  let map_validate t ~f ctx state1 =
    let x, state2 = t ctx state1 in
    match f x with
    | Result.Ok x -> (x, state2)
    | Error msg ->
      let parsed =
        Name_map.merge state1.unparsed state2.unparsed
          ~f:(fun _key before after ->
            match before, after with
            | Some _, None -> before
            | _ -> None)
      in
      let loc =
        match
          Name_map.values parsed
          |> List.map ~f:(fun f -> Ast.loc f.entry)
          |> List.sort ~compare:(fun a b ->
            Int.compare a.Loc.start.pos_cnum b.start.pos_cnum)
        with
        | [] ->
          let (Fields (loc, _, _)) = ctx in
          loc
        | first :: l ->
          let last = List.fold_left l ~init:first ~f:(fun _ x -> x) in
          { first with stop = last.stop }
      in
      of_sexp_errorf loc "%s" msg

  let field_missing loc name =
    of_sexp_errorf loc "field %s missing" name
  [@@inline never]

  let rec multiple_occurrences ~name ~last ~prev =
    match prev.prev with
    | Some prev_prev ->
      (* Make the error message point to the second occurrence *)
      multiple_occurrences ~name ~last:prev ~prev:prev_prev
    | None ->
      of_sexp_errorf (Ast.loc last.entry) "Field %S is present too many times"
        name
  [@@inline never]

  let find_single state name =
    let res = Name_map.find state.unparsed name in
    (match res with
     | Some ({ prev = Some prev; _ } as last) ->
       multiple_occurrences ~name ~last ~prev
     | _ -> ());
    res

  let field name ?default t (Fields (loc, _, uc)) state =
    match find_single state name with
    | Some { values; entry; _ } ->
      let ctx = Values (Ast.loc entry, Some name, uc) in
      let x = result ctx (t ctx values) in
      (x, consume name state)
    | None ->
      match default with
      | Some v -> (v, add_known name state)
      | None -> field_missing loc name

  let field_o name t (Fields (_, _, uc)) state =
    match find_single state name with
    | Some { values; entry; _ } ->
      let ctx = Values (Ast.loc entry, Some name, uc) in
      let x = result ctx (t ctx values) in
      (Some x, consume name state)
    | None ->
      (None, add_known name state)

  let field_b ?check name =
    field name ~default:false
      (Option.value check ~default:(return ()) >>= fun () ->
        eos >>= function
       | true -> return true
       | _ -> bool)

  let multi_field name t (Fields (_, _, uc)) state =
    let rec loop acc field =
      match field with
      | None -> acc
      | Some { values; prev; entry } ->
        let ctx = Values (Ast.loc entry, Some name, uc) in
        let x = result ctx (t ctx values) in
        loop (x :: acc) prev
    in
    let res = loop [] (Name_map.find state.unparsed name) in
    (res, consume name state)

  let fields t (Values (loc, cstr, uc)) sexps =
    let unparsed =
      List.fold_left sexps ~init:Name_map.empty ~f:(fun acc sexp ->
        match sexp with
        | List (_, name_sexp :: values) -> begin
            match name_sexp with
            | Atom (_, A name) ->
              Name_map.add acc name
                { values
                ; entry = sexp
                ; prev  = Name_map.find acc name
                }
            | List (loc, _) | Quoted_string (loc, _) | Template { loc; _ } ->
              of_sexp_error loc "Atom expected"
          end
        | _ ->
          of_sexp_error (Ast.loc sexp)
            "S-expression of the form (<name> <values>...) expected")
    in
    let ctx = Fields (loc, cstr, uc) in
    let x = result ctx (t ctx { unparsed; known = [] }) in
    (x, [])

  let record t = enter (fields t)

  type kind =
    | Values of Loc.t * string option
    | Fields of Loc.t * string option

  let kind : type k. k context -> k -> kind * k
    = fun ctx state ->
      match ctx with
      | Values (loc, cstr, _) -> (Values (loc, cstr), state)
      | Fields (loc, cstr, _) -> (Fields (loc, cstr), state)
end

module type Sexpable = sig
  type t
  val t : t Of_sexp.t
  val sexp_of_t : t To_sexp.t
end
