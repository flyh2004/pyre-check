(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Statement


module type Kind = sig

  type t
  [@@deriving compare, eq, show, sexp, hash]

  val code: t -> int
  val name: t -> string
  val messages:
    concise: bool
    -> define: Define.t Node.t
    -> Location.Instantiated.t
    -> t
    -> string list
  val inference_information:
    define: Define.t Node.t
    -> t
    -> Yojson.Safe.json
end


module type Error = sig
  type kind

  type t = {
    location: Location.Instantiated.t;
    kind: kind;
    define: Statement.Define.t Node.t;
  }
  [@@deriving compare, eq, show, sexp, hash]

  include Hashable with type t := t

  val create: location: Location.t -> kind: kind -> define: Statement.Define.t Node.t -> t

  val kind: t -> kind
  val path: t -> string
  val location: t -> Location.Instantiated.t
  val key: t -> Location.t
  val code: t -> int
  val description
    :  ?separator: string
    -> ?concise: bool
    -> t
    -> show_error_traces: bool
    -> string

  val to_json: show_error_traces: bool -> t -> Yojson.Safe.json
end


module Make(Kind: Kind) = struct

  type kind = Kind.t

  type t = {
    location: Location.Instantiated.t;
    kind: Kind.t;
    define: Define.t Node.t;
  }
  [@@deriving compare, eq, show, sexp, hash]


  include Hashable.Make(struct
      type nonrec t = t
      let compare = compare
      let hash = hash
      let hash_fold_t = hash_fold_t
      let sexp_of_t = sexp_of_t
      let t_of_sexp = t_of_sexp
    end)


  let create ~location ~kind ~define  =
    {
      location =
        Location.instantiate ~lookup:(fun hash -> Ast.SharedMemory.Handles.get ~hash) location;
      kind;
      define
    }


  let kind { kind; _ } =
    kind


  let path { location = { Location.path; _ }; _ } =
    path


  let location { location; _ } =
    location


  let key { location = { Location.start = { Location.line; _ }; path; _ }; _ } =
    let start = { Location.line; column = -1 } in
    { Location.start; stop = start; path }
    |> Location.reference


  let description
      ?(separator = " ")
      ?(concise = false)
      ({
        kind;
        location;
        define;
        _;
      })
      ~show_error_traces =
    let messages = Kind.messages ~concise ~define location kind in
    Format.asprintf
      "%s [%d]: %s"
      (Kind.name kind)
      (Kind.code kind)
      (
        if show_error_traces then
          String.concat ~sep:separator messages
        else
          List.nth_exn messages 0
      )


  let show error =
    Format.asprintf "%a" pp error


  let to_json
      ~show_error_traces
      ({
        location =
          { Location.path; start = { Location.line = start_line; column = start_column }; _ };
        kind;
        define = ({ Node.value = define; _ } as define_node);
        _;
      } as error) =
    `Assoc ([
        "line", `Int (start_line);
        "column", `Int (start_column);
        "path", `String path;
        "code", `Int (Kind.code kind);
        "name", `String (Kind.name kind);
        "description", `String (description error ~show_error_traces);
        "long_description", `String (description error ~show_error_traces:true ~separator:"\n");
        "concise_description", `String (
            description error ~show_error_traces ~concise:true ~separator:"\n"
        );
        "inference", (Kind.inference_information ~define:define_node kind);
        "define", `String (Reference.show_sanitized define.Define.name);
      ])


  let code { kind; _ } =
    Kind.code kind

end
