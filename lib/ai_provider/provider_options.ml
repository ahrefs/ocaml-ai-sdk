(** Type-safe heterogeneous key-value store using extensible GADTs.

    Uses {!Obj.Extension_constructor.id} to identify keys at runtime and
    {!Obj.magic} for type recovery. This is type-safe by construction:
    two extensible variant constructors share the same [Extension_constructor.id]
    if and only if they are the same constructor, which guarantees they carry
    the same type parameter. This is the standard OCaml pattern for extensible
    GADTs, used by {!Printexc} and other stdlib modules.

    Future: OCaml 5.1+ [Type.eq] would provide a first-class type equality
    witness, eliminating the need for [Obj.magic]. *)

type _ key = ..

type entry = Entry : 'a key * 'a -> entry

type t = entry list

let empty = []

let set (type a) (k : a key) (v : a) (opts : t) : t =
  let kid = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k) in
  let replaced = ref false in
  let opts' =
    List.filter_map
      (fun (Entry (k', _) as e) ->
        let kid' = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k') in
        if Int.equal kid kid' then begin
          replaced := true;
          Some (Entry (k, v))
        end
        else Some e)
      opts
  in
  if !replaced then opts' else Entry (k, v) :: opts

(* NOTE on Obj.magic: This is the standard pattern for extensible GADT
   existentials in OCaml. When two extensible variant constructors have the
   same Extension_constructor.id, they are the same constructor and thus
   carry the same type parameter. The Obj.magic is therefore type-safe.
   This is the same approach used by Printexc and other stdlib modules. *)
let find (type a) (k : a key) (opts : t) : a option =
  let kid = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k) in
  let rec go = function
    | [] -> None
    | Entry (k', v) :: rest ->
      let kid' = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k') in
      if Int.equal kid' kid then Some (Obj.magic v : a) else go rest
  in
  go opts

let find_exn k opts =
  match find k opts with
  | Some v -> v
  | None -> raise Not_found
