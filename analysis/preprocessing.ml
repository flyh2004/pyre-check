(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Expression
open Pyre
open PyreParser
open Statement


exception MissingWildcardImport


let expand_relative_imports ({ Source.handle; qualifier; _ } as source) =
  let module Transform = Transform.MakeStatementTransformer(struct
      type t = Access.t

      let statement qualifier { Node.location; value } =
        let value =
          match value with
          | Import { Import.from = Some from; imports }
            when Access.show from <> "builtins" && Access.show from <> "future.builtins" ->
              Import {
                Import.from = Some (Source.expand_relative_import ~handle ~qualifier ~from);
                imports;
              }
          | _ ->
              value
        in
        qualifier, [{ Node.location; value }]
    end)
  in
  Transform.transform (Reference.access qualifier) source
  |> Transform.source


let expand_string_annotations ({ Source.handle; _ } as source) =
  let module Transform = Transform.Make(struct
      type t = unit

      let transform_children _ _ = true

      let transform_string_annotation_expression handle =
        let rec transform_expression
            ({
              Node.location = {
                Location.start = { Location.line = start_line; column = start_column};
                _;
              } as location;
              value
            } as expression) =
          let value =
            let transform_element = function
              | Access.Call ({ Node.value = arguments ; _ } as call) ->
                  let transform_argument ({ Argument.value; _ } as argument) =
                    { argument with Argument.value = transform_expression value }
                  in
                  Access.Call {
                    call with
                    Node.value = List.map arguments ~f:transform_argument;
                  }
              | element ->
                  element
            in
            match value with
            | Access (SimpleAccess access) ->
                (* This will hit any generic type named Literal, but otherwise from ... import
                   Literal woudln't work as this has to be before qualification. *)
                let transform_everything_but_literal (reversed_access, in_literal) element =
                  let element, in_literal =
                    match element, in_literal with
                    | Access.Identifier "Literal", _ ->
                        transform_element element, true
                    | Access.Identifier "__getitem__", _ ->
                        transform_element element, in_literal
                    | Access.Call _, true ->
                        element, false
                    | _, _ ->
                        transform_element element, false
                  in
                  element :: reversed_access, in_literal
                in
                let access =
                  List.fold access ~f:transform_everything_but_literal ~init:([], false)
                  |> fst
                  |> List.rev
                in
                Access (SimpleAccess (access))
            | Access (ExpressionAccess { expression; access }) ->
                Access
                  (ExpressionAccess {
                      expression = transform_expression expression;
                      access = List.map access ~f:transform_element;
                    })
            | String { StringLiteral.value; _ } ->
                let parsed =
                  try
                    (* Start at column + 1 since parsing begins after
                       the opening quote of the string literal. *)
                    match
                      Parser.parse
                        ~start_line
                        ~start_column:(start_column + 1)
                        [value ^ "\n"]
                        ~handle
                    with
                    | [{ Node.value = Expression { Node.value = Access access; _ } ; _ }] ->
                        Some access
                    | _ ->
                        failwith "Not an access"
                  with
                  | Parser.Error _
                  | Failure _ ->
                      begin
                        Log.debug
                          "Invalid string annotation `%s` at %a"
                          value
                          Location.Reference.pp
                          location;
                        None
                      end
                in
                parsed
                >>| (fun parsed -> Access parsed)
                |> Option.value
                  ~default:(Access (SimpleAccess (Access.create "$unparsed_annotation")))
            | Tuple elements ->
                Tuple (List.map elements ~f:transform_expression)
            | _ ->
                value
          in
          { expression with Node.value }
        in
        transform_expression

      let statement _ ({ Node.value; _ } as statement) =
        let transform_assign ~assign:({ Assign.annotation; _ } as assign) =
          {
            assign with
            Assign.annotation = annotation >>| transform_string_annotation_expression handle
          }
        in
        let transform_define ~define:({ Define.parameters; return_annotation; _ } as define) =
          let parameter ({ Node.value = ({ Parameter.annotation; _ } as parameter); _ } as node) =
            {
              node with
              Node.value = {
                parameter with
                Parameter.annotation = annotation >>| transform_string_annotation_expression handle;
              };
            }
          in
          {
            define with
            Define.parameters = List.map parameters ~f:parameter;
            return_annotation = return_annotation >>| transform_string_annotation_expression handle;
          }
        in
        let statement =
          let value =
            match value with
            | Assign assign -> Assign (transform_assign ~assign)
            | Define define -> Define (transform_define ~define)
            | _ -> value
          in
          { statement with Node.value }
        in
        (), [statement]

      let expression _ expression =
        let transform_call_access = function
          | ({ Node.value = [
              ({
                Argument.name = None;
                value = ({ Node.value = String _; _ } as value)
              } as type_argument);
              value_argument;
            ]; _ } as call) ->
              let annotation = transform_string_annotation_expression handle value in
              let value = [{ type_argument with value = annotation }; value_argument] in
              { call with value }
          | _ as call -> call
        in
        let value =
          match Node.value expression with
          | Access (SimpleAccess [
              Identifier "cast" as cast_identifier;
              Call call;
            ]) ->
              let call = Access.Call (transform_call_access call) in
              Access (SimpleAccess [cast_identifier; call])
          | Access (SimpleAccess [
              Identifier "typing" as typing_identifier;
              Identifier "cast" as cast_identifier;
              Call call;
            ]) ->
              let call = Access.Call (transform_call_access call) in
              Access (Access.SimpleAccess [typing_identifier; cast_identifier; call])
          | value -> value
        in
        { expression with Node.value }
    end)
  in
  Transform.transform () source
  |> Transform.source


let expand_format_string ({ Source.handle; _ } as source) =
  let module Transform = Transform.Make(struct
      include Transform.Identity
      type t = unit

      type state =
        | Literal
        | Expression of int * string

      let expression _ expression =
        match expression with
        | {
          Node.location = ({ Location.start = { Location.line; column }; _ } as location);
          value = String { StringLiteral.value; kind = StringLiteral.Mixed substrings; _ };
        } ->
            let gather_fstring_expressions substrings =
              let gather_expressions_in_substring
                  (current_position, expressions)
                  { StringLiteral.Substring.kind; value } =
                let value_length = String.length value in
                let rec expand_fstring input_string start_position state: ('a list) =
                  if start_position = value_length then
                    []
                  else
                    let token = String.get input_string start_position in
                    let expressions, next_state =
                      match token, state with
                      | '{', Literal ->
                          [], Expression (start_position, "")
                      | '{', Expression (_, "") ->
                          [], Literal
                      | '}', Literal ->
                          [], Literal
                      (* NOTE: this does not account for nested expressions in
                          e.g. format specifiers. *)
                      | '}', Expression (c, string) ->
                          [(column + current_position + c, string)], Literal
                      (* Ignore leading whitespace in expressions. *)
                      | (' ' | '\t'), (Expression (_, "") as expression) ->
                          [], expression
                      | _, Literal ->
                          [], Literal
                      | _, Expression (c, string) ->
                          [], Expression (c, string ^ (Char.to_string token))
                    in
                    let next_expressions =
                      expand_fstring input_string (start_position + 1) next_state
                    in
                    expressions @ next_expressions
                in
                let next_position = current_position + value_length in
                match kind with
                | StringLiteral.Substring.Literal ->
                    next_position, expressions
                | StringLiteral.Substring.Format ->
                    let fstring_expressions = expand_fstring value 0 Literal in
                    next_position, (List.rev fstring_expressions) @ expressions
              in
              List.fold substrings ~init:(0, []) ~f:gather_expressions_in_substring
              |> snd
              |> List.rev
            in
            let parse (start_column, input_string) =
              try
                let string = input_string ^ "\n" in
                match Parser.parse [string ^ "\n"] ~start_line:line ~start_column ~handle with
                | [{ Node.value = Expression expression; _ }] -> [expression]
                | _ -> failwith "Not an expression"
              with
              | Parser.Error _
              | Failure _ ->
                  begin
                    Log.debug
                      "Pyre could not parse format string `%s` at %a"
                      input_string
                      Location.Reference.pp
                      location;
                    []
                  end
            in
            let expressions =
              substrings
              |> gather_fstring_expressions
              |> List.concat_map ~f:parse
            in
            { Node.location; value = String { StringLiteral.kind = Format expressions; value } }
        | _ ->
            expression
    end)
  in
  Transform.transform () source
  |> Transform.source


type alias = {
  access: Access.t;
  qualifier: Access.t;
  is_forward_reference: bool;
}


type scope = {
  qualifier: Access.t;
  aliases: alias Access.Map.t;
  immutables: Access.Set.t;
  locals: Access.Set.t;
  use_forward_references: bool;
  is_top_level: bool;
  skip: Location.Reference.Set.t;
}

let qualify_local_identifier name ~qualifier =
  let qualifier =
    Access.show qualifier
    |> String.substr_replace_all ~pattern:"." ~with_:"?"
  in
  name
  |> Format.asprintf "$local_%s$%s" qualifier
  |> fun identifier -> [Access.Identifier identifier]


let qualify ({ Source.handle; qualifier = source_qualifier; statements; _ } as source) =
  let prefix_identifier ~scope:({ aliases; immutables; _ } as scope) ~prefix name =
    let stars, name =
      if String.is_prefix name ~prefix:"**" then
        "**", String.drop_prefix name 2
      else if String.is_prefix name ~prefix:"*" then
        "*", String.drop_prefix name 1
      else
        "", name
    in
    let renamed =
      Format.asprintf "$%s$%s" prefix name
    in
    let access = [Access.Identifier name] in
    {
      scope with
      aliases =
        Map.set
          aliases
          ~key:access
          ~data:{
            access = [Access.Identifier renamed];
            qualifier = Reference.access source_qualifier;
            is_forward_reference = false;
          };
      immutables = Set.add immutables access;
    },
    stars,
    renamed
  in
  let rec explore_scope ~scope statements =
    let global_alias ~qualifier ~name =
      {
        access = qualifier @ name;
        qualifier;
        is_forward_reference = true;
      }
    in
    let explore_scope
        ({ qualifier; aliases; immutables; skip; _ } as scope)
        { Node.location; value } =
      match value with
      | Assign {
          Assign.target = { Node.value = Access (SimpleAccess name); _ };
          annotation = Some annotation;
          _;
        }
        when Expression.show annotation = "_SpecialForm" ->
          {
            scope with
            aliases = Map.set aliases ~key:name ~data:(global_alias ~qualifier ~name);
            skip = Set.add skip location;
          }
      | Class { Class.name; _ } ->
          let name = Reference.access name in
          {
            scope with
            aliases = Map.set aliases ~key:name ~data:(global_alias ~qualifier ~name);
          }
      | Define { Define.name; _ } ->
          let name = Reference.access name in
          {
            scope with
            aliases = Map.set aliases ~key:name ~data:(global_alias ~qualifier ~name);
          }
      | If { If.body; orelse; _ } ->
          let scope = explore_scope ~scope body in
          explore_scope ~scope orelse
      | For { For.body; orelse; _ } ->
          let scope = explore_scope ~scope body in
          explore_scope ~scope orelse
      | Global identifiers ->
          let immutables =
            let register_global immutables identifier =
              Set.add immutables [Access.Identifier identifier]
            in
            List.fold identifiers ~init:immutables ~f:register_global
          in
          { scope with immutables }
      | Try { Try.body; handlers; orelse; finally } ->
          let scope = explore_scope ~scope body in
          let scope =
            let explore_handler scope { Try.handler_body; _ } =
              explore_scope ~scope handler_body
            in
            List.fold handlers ~init:scope ~f:explore_handler
          in
          let scope = explore_scope ~scope orelse in
          explore_scope ~scope finally
      | With { With.body; _ } ->
          explore_scope ~scope body
      | While { While.body; orelse; _ } ->
          let scope = explore_scope ~scope body in
          explore_scope ~scope orelse
      | _ ->
          scope
    in
    List.fold statements ~init:scope ~f:explore_scope
  in
  let rec qualify_parameters ~scope parameters =
    (* Rename parameters to prevent aliasing. *)
    let parameters =
      let qualify_annotation { Node.location; value = { Parameter.annotation; _ } as parameter } =
        {
          Node.location;
          value = {
            parameter with
            Parameter.annotation = annotation >>| qualify_expression ~qualify_strings:true ~scope;
          };
        }
      in
      List.map parameters ~f:qualify_annotation
    in
    let rename_parameter
        (scope, reversed_parameters)
        ({ Node.value = { Parameter.name; value; annotation }; _ } as parameter) =
      let scope, stars, renamed = prefix_identifier ~scope ~prefix:"parameter" name in
      scope,
      {
        parameter with
        Node.value = {
          Parameter.name = stars ^ renamed;
          value = value >>| qualify_expression ~qualify_strings:false ~scope;
          annotation;
        };
      } :: reversed_parameters
    in
    let scope, parameters =
      List.fold
        parameters
        ~init:({ scope with locals = Access.Set.empty }, [])
        ~f:rename_parameter
    in
    scope, List.rev parameters

  and qualify_statements ?(qualify_assigns = false) ~scope statements =
    let scope = explore_scope ~scope statements in
    let scope, reversed_statements =
      let qualify (scope, statements) statement =
        let scope, statement = qualify_statement ~qualify_assign:qualify_assigns ~scope statement in
        scope, statement :: statements
      in
      List.fold statements ~init:(scope, []) ~f:qualify
    in
    scope, List.rev reversed_statements

  and qualify_statement
      ~qualify_assign
      ~scope:({ qualifier; aliases; skip; is_top_level; _ } as scope)
      ({ Node.location; value } as statement) =
    let scope, value =
      let local_alias ~qualifier ~access = { access; qualifier; is_forward_reference = false } in

      let qualify_assign { Assign.target; annotation; value; parent } =
        let value =
          match value with
          | { Node.value = String _; _ } ->
              (* String literal assignments might be type aliases. *)
              qualify_expression ~qualify_strings:is_top_level value ~scope
          | {
            Node.value =
              Access
                (SimpleAccess
                   (Access.Identifier _ :: Access.Identifier "__getitem__" :: _));
            _;
          } ->
              qualify_expression ~qualify_strings:is_top_level value ~scope
          | _ ->
              qualify_expression ~qualify_strings:false value ~scope
        in
        let target_scope, target =
          if not (Set.mem skip location) then
            let rec qualify_target ~scope:({ aliases; immutables; locals; _ } as scope) target =
              let scope, value =
                let qualify_targets scope elements =
                  let qualify_element (scope, reversed_elements) element =
                    let scope, element = qualify_target ~scope element in
                    scope, element :: reversed_elements
                  in
                  let scope, reversed_elements =
                    List.fold elements ~init:(scope, []) ~f:qualify_element
                  in
                  scope, List.rev reversed_elements
                in
                match Node.value target with
                | Tuple elements ->
                    let scope, elements = qualify_targets scope elements in
                    scope, Tuple elements
                | List elements ->
                    let scope, elements = qualify_targets scope elements in
                    scope, List elements
                | Access (SimpleAccess ([_] as access)) when qualify_assign ->
                    (* Qualify field assignments in class body. *)
                    let sanitized =
                      match access with
                      | [Access.Identifier name] ->
                          [Access.Identifier (Identifier.sanitized name)]
                      | access ->
                          access
                    in
                    let scope =
                      let aliases =
                        let update = function
                          | Some alias -> alias
                          | None -> local_alias ~qualifier ~access:(qualifier @ sanitized)
                        in
                        Map.update aliases access ~f:update
                      in
                      { scope with aliases }
                    in
                    let qualified = qualifier @ sanitized in
                    scope, Access (SimpleAccess qualified)
                | Starred (Starred.Once access) ->
                    let scope, access = qualify_target ~scope access in
                    scope, Starred (Starred.Once access)
                | Access (SimpleAccess ([Access.Identifier name] as access)) ->
                    (* Incrementally number local variables to avoid shadowing. *)
                    let scope =
                      let qualified = String.is_prefix name ~prefix:"$" in
                      if not qualified &&
                         not (Set.mem locals access) &&
                         not (Set.mem immutables access) then
                        let alias = qualify_local_identifier name ~qualifier in
                        {
                          scope with
                          aliases =
                            Map.set
                              aliases
                              ~key:access
                              ~data:(local_alias ~qualifier ~access:alias);
                          locals = Set.add locals access;
                        }
                      else
                        scope
                    in
                    scope,
                    Access (SimpleAccess (qualify_access ~qualify_strings:false ~scope access))
                | Access (SimpleAccess access) ->
                    let access =
                      let qualified =
                        match qualify_access ~qualify_strings:false ~scope access with
                        | [Access.Identifier name] ->
                            [Access.Identifier (Identifier.sanitized name)]
                        | qualified ->
                            qualified
                      in
                      if qualify_assign then
                        qualifier @ qualified
                      else
                        qualified
                    in
                    scope, Access (SimpleAccess access)
                | target ->
                    scope, target
              in
              scope, { target with Node.value }
            in
            qualify_target ~scope target
          else
            scope, target
        in
        target_scope,
        {
          Assign.target;
          annotation = annotation >>| qualify_expression ~qualify_strings:true ~scope;
          (* Assignments can be type aliases. *)
          value;
          parent = parent >>| fun parent -> qualify_reference ~qualify_strings:false ~scope parent;
        }
      in
      let qualify_define
          ({ qualifier; _ } as scope)
          ({
            Define.name;
            parameters;
            body;
            decorators;
            return_annotation;
            parent;
            _;
          } as define) =
        let scope = { scope with is_top_level = false } in
        let return_annotation =
          return_annotation
          >>| qualify_expression ~qualify_strings:true ~scope
        in
        let parent =
          parent
          >>| fun parent -> qualify_reference ~qualify_strings:false ~scope parent
        in
        let decorators =
          List.map
            decorators
            ~f:(qualify_expression
                  ~qualify_strings:false
                  ~scope:{ scope with use_forward_references = true })
        in
        let scope, parameters = qualify_parameters ~scope parameters in
        let qualifier = qualifier @ (Reference.access name) in
        let _, body = qualify_statements ~scope:{ scope with qualifier } body in
        {
          define with
          Define.name =
            qualify_reference ~suppress_synthetics:true ~qualify_strings:false ~scope name;
          parameters;
          body;
          decorators;
          return_annotation;
          parent;
        }
      in
      let qualify_class ({ Class.name; bases; body; decorators; _ } as definition) =
        let scope = { scope with is_top_level = false } in
        let qualify_base ({ Argument.value; _ } as argument) =
          { argument with Argument.value = qualify_expression ~qualify_strings:false ~scope value }
        in
        let decorators =
          List.map
            decorators
            ~f:(qualify_expression ~qualify_strings:false ~scope)
        in
        let body =
          let qualifier = qualifier @ (Reference.access name) in
          let original_scope = { scope with qualifier } in
          let scope = explore_scope body ~scope:original_scope in
          let qualify (scope, statements) ({ Node.location; value } as statement) =
            let scope, statement =
              match value with
              | Define ({ Define.name; parameters; return_annotation; decorators; _ } as define) ->
                  let define = qualify_define original_scope define in
                  let _, parameters = qualify_parameters ~scope parameters in
                  let return_annotation =
                    return_annotation
                    >>| qualify_expression ~scope ~qualify_strings:true
                  in
                  let qualify_decorator ({ Node.value; _ } as decorator) =
                    let is_reserved = function
                      | [] -> false
                      | [Access.Identifier ("staticmethod" | "classmethod" | "property")] -> true
                      | accesses ->
                          match List.last_exn accesses with
                          | Access.Identifier ("getter" | "setter" | "deleter") -> true
                          | _ -> false
                    in
                    match value with
                    | Access (Access.SimpleAccess accesses) when is_reserved accesses ->
                        decorator
                    | _ ->
                        (* TODO (T41755857): Decorator qualification logic
                           should be slightly more involved than this. *)
                        qualify_expression ~qualify_strings:false ~scope decorator
                  in
                  let decorators = List.map decorators ~f:qualify_decorator in
                  scope, {
                    Node.location;
                    value = Define {
                        define with
                        Define.name = qualify_reference ~qualify_strings:false ~scope name;
                        parameters;
                        decorators;
                        return_annotation;
                      };
                  }
              | _ ->
                  qualify_statement statement ~qualify_assign:true ~scope
            in
            scope, statement :: statements
          in
          List.fold body ~init:(scope, []) ~f:qualify
          |> snd
          |> List.rev
        in
        {
          definition with
          (* Ignore aliases, imports, etc. when declaring a class name. *)
          Class.name = Reference.combine (Reference.from_access scope.qualifier) name;
          bases = List.map bases ~f:qualify_base;
          body;
          decorators;
        }
      in

      let join_scopes left right =
        let merge ~key:_ = function
          | `Both (left, _) -> Some left
          | `Left left -> Some left
          | `Right right -> Some right
        in
        {
          left with
          aliases = Map.merge left.aliases right.aliases ~f:merge;
          locals = Set.union left.locals right.locals;
        }
      in

      match value with
      | Assign assign ->
          let scope, assign = qualify_assign assign in
          scope, Assign assign
      | Assert { Assert.test; message; origin } ->
          scope,
          Assert {
            Assert.test = qualify_expression ~qualify_strings:false ~scope test;
            message;
            origin;
          }
      | Class ({ name; _ } as definition) ->
          let scope = {
            scope with
            aliases =
              Map.set
                aliases
                ~key:(Reference.access name)
                ~data:(local_alias ~qualifier ~access:(qualifier @ (Reference.access name)));
          }
          in
          scope,
          Class (qualify_class definition)
      | Define define ->
          scope,
          Define (qualify_define scope define)
      | Delete expression ->
          scope,
          Delete (qualify_expression ~qualify_strings:false ~scope expression)
      | Expression expression ->
          scope,
          Expression (qualify_expression ~qualify_strings:false ~scope expression)
      | For ({ For.target; iterator; body; orelse; _ } as block) ->
          let renamed_scope, target = qualify_target ~scope target in
          let body_scope, body = qualify_statements ~scope:renamed_scope body in
          let orelse_scope, orelse = qualify_statements ~scope:renamed_scope orelse in
          join_scopes body_scope orelse_scope,
          For {
            block with
            For.target;
            iterator = qualify_expression ~qualify_strings:false ~scope iterator;
            body;
            orelse;
          }
      | Global identifiers ->
          scope,
          Global identifiers
      | If { If.test; body; orelse } ->
          let body_scope, body = qualify_statements ~scope body in
          let orelse_scope, orelse = qualify_statements ~scope orelse in
          join_scopes body_scope orelse_scope,
          If { If.test = qualify_expression ~qualify_strings:false ~scope test; body; orelse }
      | Import { Import.from = Some from; imports }
        when Access.show from <> "builtins" ->
          let import aliases { Import.name; alias } =
            match alias with
            | Some alias ->
                (* Add `alias -> from.name`. *)
                Map.set aliases ~key:alias ~data:(local_alias ~qualifier ~access:(from @ name))
            | None ->
                (* Add `name -> from.name`. *)
                Map.set aliases ~key:name ~data:(local_alias ~qualifier ~access:(from @ name))
          in
          { scope with aliases = List.fold imports ~init:aliases ~f:import },
          value
      | Import { Import.from = None; imports } ->
          let import aliases { Import.name; alias } =
            match alias with
            | Some alias ->
                (* Add `alias -> from.name`. *)
                Map.set aliases ~key:alias ~data:(local_alias ~qualifier ~access:name)
            | None ->
                aliases
          in
          { scope with aliases = List.fold imports ~init:aliases ~f:import },
          value
      | Nonlocal identifiers  ->
          scope,
          Nonlocal identifiers
      | Raise expression ->
          scope,
          Raise (expression >>| qualify_expression ~qualify_strings:false ~scope)
      | Return ({ Return.expression; _ } as return) ->
          scope,
          Return {
            return with
            Return.expression = expression >>| qualify_expression ~qualify_strings:false ~scope;
          }
      | Try { Try.body; handlers; orelse; finally } ->
          let body_scope, body = qualify_statements ~scope body in
          let handler_scopes, handlers =
            let qualify_handler { Try.kind; name; handler_body } =
              let renamed_scope, name =
                match name with
                | Some name ->
                    let scope, _, renamed = prefix_identifier ~scope ~prefix:"target" name in
                    scope, Some renamed
                | _ ->
                    scope, name
              in
              let kind = kind >>| qualify_expression ~qualify_strings:false ~scope in
              let scope, handler_body = qualify_statements ~scope:renamed_scope handler_body in
              scope, { Try.kind; name; handler_body }
            in
            List.map handlers ~f:qualify_handler
            |> List.unzip
          in
          let orelse_scope, orelse = qualify_statements ~scope:body_scope orelse in
          let finally_scope, finally = qualify_statements ~scope finally in
          let scope =
            List.fold handler_scopes ~init:body_scope ~f:join_scopes
            |> join_scopes orelse_scope
            |> join_scopes finally_scope
          in
          scope,
          Try { Try.body; handlers; orelse; finally }
      | With ({ With.items; body; _ } as block) ->
          let scope, items =
            let qualify_item (scope, reversed_items) (name, alias) =
              let scope, item =
                let renamed_scope, alias =
                  match alias with
                  | Some alias ->
                      let scope, alias = qualify_target ~scope alias in
                      scope, Some alias
                  | _ ->
                      scope, alias
                in
                renamed_scope,
                (qualify_expression ~qualify_strings:false ~scope name, alias)
              in
              scope, item :: reversed_items
            in
            let scope, reversed_items = List.fold items ~init:(scope, []) ~f:qualify_item in
            scope, List.rev reversed_items
          in
          let scope, body = qualify_statements ~scope body in
          scope,
          With { block with With.items; body }
      | While { While.test; body; orelse } ->
          let body_scope, body = qualify_statements ~scope body in
          let orelse_scope, orelse = qualify_statements ~scope orelse in
          join_scopes body_scope orelse_scope,
          While { While.test = qualify_expression ~qualify_strings:false ~scope test; body; orelse }
      | Statement.Yield expression ->
          scope,
          Statement.Yield (qualify_expression ~qualify_strings:false ~scope expression)
      | Statement.YieldFrom expression ->
          scope,
          Statement.YieldFrom (qualify_expression ~qualify_strings:false ~scope expression)
      | Break | Continue | Import _ | Pass ->
          scope,
          value
    in
    scope, { statement with Node.value }

  and qualify_target ~scope target =
    let rec renamed_scope ({ locals; _ } as scope) target =
      match target with
      | { Node.value = Tuple elements; _ } ->
          List.fold elements ~init:scope ~f:renamed_scope
      | { Node.value = Access (SimpleAccess ([Access.Identifier name] as access)); _ } ->
          if Set.mem locals access then
            scope
          else
            let scope, _, _ = prefix_identifier ~scope ~prefix:"target" name in
            scope
      | _ ->
          scope
    in
    let scope = renamed_scope scope target in
    scope, qualify_expression ~qualify_strings:false ~scope target

  and qualify_access
      ?(suppress_synthetics = false)
      ~qualify_strings
      ~scope:({ aliases; use_forward_references; _ } as scope)
      access =
    match access with
    | head :: tail ->
        let head =
          match Map.find aliases [head] with
          | Some { access; is_forward_reference; qualifier }
            when (not is_forward_reference) || use_forward_references ->
              if Access.show access |> String.is_prefix ~prefix:"$" &&
                 suppress_synthetics then
                qualifier @ [head]
              else
                access
          | _ ->
              [head]
        in
        let qualify_element reversed_lead element =
          let element =
            match element with
            | Access.Call ({ Node.value = arguments ; _ } as call) ->
                let qualify_strings =
                  match reversed_lead with
                  | [Access.Identifier "TypeVar"; Access.Identifier "typing"] ->
                      true
                  | _ ->
                      qualify_strings
                in
                let qualify_argument { Argument.name; value } =
                  let name =
                    let rename identifier = "$parameter$" ^ identifier in
                    name
                    >>| Node.map ~f:rename
                  in
                  { Argument.name; value = qualify_expression ~qualify_strings ~scope value }
                in
                Access.Call { call with Node.value = List.map arguments ~f:qualify_argument }
            | element ->
                element
          in
          element :: reversed_lead
        in
        List.fold (head @ tail) ~f:qualify_element ~init:[]
        |> List.rev
    | _ ->
        access

  and qualify_reference ?(suppress_synthetics = false) ~qualify_strings ~scope reference =
    Reference.access reference
    |> qualify_access ~suppress_synthetics ~qualify_strings ~scope
    |> Reference.from_access

  and qualify_expression
      ~qualify_strings
      ~scope:({ qualifier; _ } as scope)
      ({ Node.location; value } as expression) =
    let value =
      let qualify_entry ~qualify_strings ~scope { Dictionary.key; value } =
        {
          Dictionary.key = qualify_expression ~qualify_strings ~scope key;
          value = qualify_expression ~qualify_strings ~scope value;
        }
      in
      let qualify_generators ~qualify_strings ~scope generators =
        let qualify_generator
            (scope, reversed_generators)
            ({ Comprehension.target; iterator; conditions; _ } as generator) =
          let renamed_scope, target = qualify_target ~scope target in
          renamed_scope,
          {
            generator with
            Comprehension.target;
            iterator = qualify_expression ~qualify_strings ~scope iterator;
            conditions =
              List.map
                conditions
                ~f:(qualify_expression ~qualify_strings ~scope:renamed_scope);
          } :: reversed_generators
        in
        let scope, reversed_generators =
          List.fold
            generators
            ~init:(scope, [])
            ~f:qualify_generator
        in
        scope, List.rev reversed_generators
      in
      match value with
      | Access (SimpleAccess access) ->
          Access (SimpleAccess (qualify_access ~qualify_strings ~scope access))
      | Access (ExpressionAccess { expression; access }) ->
          let access =
            (* We still want to qualify sub-accesses, e.g. arguments; but not the access after the
               expression. *)
            qualify_access ~qualify_strings ~scope access
            |> Access.drop_prefix ~prefix:qualifier
          in
          Access
            (ExpressionAccess {
                expression = qualify_expression ~qualify_strings ~scope expression;
                access;
              })
      | Await expression ->
          Await (qualify_expression ~qualify_strings ~scope expression)
      | BooleanOperator { BooleanOperator.left; operator; right } ->
          BooleanOperator {
            BooleanOperator.left = qualify_expression ~qualify_strings ~scope left;
            operator;
            right = qualify_expression ~qualify_strings ~scope right;
          }
      | Call expression ->
          (* TODO: T37313693 *)
          Call expression
      | ComparisonOperator { ComparisonOperator.left; operator; right } ->
          ComparisonOperator {
            ComparisonOperator.left = qualify_expression ~qualify_strings ~scope left;
            operator;
            right = qualify_expression ~qualify_strings ~scope right;
          }
      | Dictionary { Dictionary.entries; keywords } ->
          Dictionary {
            Dictionary.entries = List.map entries ~f:(qualify_entry ~qualify_strings ~scope);
            keywords = List.map keywords ~f:(qualify_expression ~qualify_strings ~scope);
          }
      | DictionaryComprehension { Comprehension.element; generators } ->
          let scope, generators = qualify_generators ~qualify_strings ~scope generators in
          DictionaryComprehension {
            Comprehension.element = qualify_entry ~qualify_strings ~scope element;
            generators;
          }
      | Generator { Comprehension.element; generators } ->
          let scope, generators = qualify_generators ~qualify_strings ~scope generators in
          Generator {
            Comprehension.element = qualify_expression ~qualify_strings ~scope element;
            generators;
          }
      | Lambda { Lambda.parameters; body } ->
          let scope, parameters = qualify_parameters ~scope parameters in
          Lambda {
            Lambda.parameters;
            body = qualify_expression ~qualify_strings ~scope body;
          }
      | List elements ->
          List (List.map elements ~f:(qualify_expression ~qualify_strings ~scope))
      | ListComprehension { Comprehension.element; generators } ->
          let scope, generators = qualify_generators ~qualify_strings ~scope generators in
          ListComprehension {
            Comprehension.element = qualify_expression ~qualify_strings ~scope element;
            generators;
          }
      | Name expression ->
          (* TODO: T37313693 *)
          Name expression
      | Set elements ->
          Set (List.map elements ~f:(qualify_expression ~qualify_strings ~scope))
      | SetComprehension { Comprehension.element; generators } ->
          let scope, generators = qualify_generators ~qualify_strings ~scope generators in
          SetComprehension {
            Comprehension.element = qualify_expression ~qualify_strings ~scope element;
            generators;
          }
      | Starred (Starred.Once expression) ->
          Starred (Starred.Once (qualify_expression ~qualify_strings ~scope expression))
      | Starred (Starred.Twice expression) ->
          Starred (Starred.Twice (qualify_expression ~qualify_strings ~scope expression))
      | String { StringLiteral.value; kind } ->
          begin
            let kind =
              match kind with
              | StringLiteral.Format expressions ->
                  StringLiteral.Format
                    (List.map expressions ~f:(qualify_expression ~qualify_strings ~scope))
              | _ ->
                  kind
            in
            if qualify_strings then
              try
                match Parser.parse [value ^ "\n"] ~handle with
                | [{ Node.value = Expression expression; _ }] ->
                    qualify_expression ~qualify_strings ~scope expression
                    |> Expression.show
                    |> fun value -> String { StringLiteral.value; kind }
                | _ ->
                    failwith "Not an expression"
              with
              | Parser.Error _
              | Failure _ ->
                  begin
                    Log.debug
                      "Invalid string annotation `%s` at %a"
                      value
                      Location.Reference.pp
                      location;
                    String { StringLiteral.value; kind }
                  end
            else
              String { StringLiteral.value; kind }
          end
      | Ternary { Ternary.target; test; alternative } ->
          Ternary {
            Ternary.target = qualify_expression ~qualify_strings ~scope target;
            test = qualify_expression ~qualify_strings ~scope test;
            alternative = qualify_expression ~qualify_strings ~scope alternative;
          }
      | Tuple elements ->
          Tuple (List.map elements ~f:(qualify_expression ~qualify_strings ~scope))
      | UnaryOperator { UnaryOperator.operator; operand } ->
          UnaryOperator {
            UnaryOperator.operator;
            operand = qualify_expression ~qualify_strings ~scope operand;
          }
      | Yield (Some expression) ->
          Yield (Some (qualify_expression ~qualify_strings ~scope expression))
      | Yield None ->
          Yield None
      | Complex _ | Ellipsis | False | Float _ | Integer _ | True ->
          value
    in
    { expression with Node.value }
  in

  let scope =
    {
      qualifier = Reference.access source_qualifier;
      aliases = Access.Map.empty;
      locals = Access.Set.empty;
      immutables = Access.Set.empty;
      use_forward_references = true;
      is_top_level = true;
      skip = Location.Reference.Set.empty;
    }
  in
  { source with Source.statements = qualify_statements ~scope statements |> snd }


let replace_version_specific_code source =
  let module Transform = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = unit

      type operator =
        | Equality of Expression.t * Expression.t
        | Comparison of Expression.t * Expression.t
        | Neither

      let statement _ ({ Node.location; value } as statement) =
        match value with
        | If { If.test; body; orelse } ->
            (* Normalizes a comparison of a < b, a <= b, b >= a or b > a to Some (a, b). *)
            let extract_single_comparison { Node.value; _ } =
              match value with
              | Expression.ComparisonOperator {
                  Expression.ComparisonOperator.left;
                  operator;
                  right;
                } ->
                  begin
                    match operator with
                    | Expression.ComparisonOperator.LessThan
                    | Expression.ComparisonOperator.LessThanOrEquals ->
                        Comparison (left, right)

                    | Expression.ComparisonOperator.GreaterThan
                    | Expression.ComparisonOperator.GreaterThanOrEquals ->
                        Comparison (right, left)

                    | Expression.ComparisonOperator.Equals ->
                        Equality (left, right)
                    | _ ->
                        Neither
                  end
              | _ ->
                  Neither
            in
            let add_pass_statement ~location body =
              if List.is_empty body then
                [Node.create ~location Statement.Pass]
              else
                body
            in
            begin
              match extract_single_comparison test with
              | Comparison
                  (left,
                   {
                     Node.value = Expression.Tuple ({ Node.value = Expression.Integer 3; _ } :: _);
                     _;
                   })
                when Expression.show left = "sys.version_info" ->
                  (), add_pass_statement ~location orelse
              | Comparison (left, { Node.value = Expression.Integer 3; _ })
                when Expression.show left = "sys.version_info[0]" ->
                  (), add_pass_statement ~location orelse
              | Comparison
                  ({ Node.value = Expression.Tuple ({ Node.value = major; _ } :: _); _ }, right)
                when Expression.show right = "sys.version_info" && major = Expression.Integer 3 ->
                  (), add_pass_statement ~location body
              | Comparison ({ Node.value = Expression.Integer 3; _ }, right)
                when Expression.show right = "sys.version_info[0]" ->
                  (), add_pass_statement ~location body
              | Equality (left, right)
                when String.is_prefix ~prefix:"sys.version_info" (Expression.show left) ||
                     String.is_prefix ~prefix:"sys.version_info" (Expression.show right) ->
                  (* Never pin our stubs to a python version. *)
                  (), add_pass_statement ~location orelse
              | _ ->
                  (), [statement]
            end
        | _ ->
            (), [statement]
    end)
  in
  Transform.transform () source
  |> Transform.source


let replace_platform_specific_code source =
  let module Transform = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = unit

      let statement _ ({ Node.location; value } as statement) =
        match value with
        | If { If.test = { Node.value = test; _ }; body; orelse } ->
            begin
              let statements =
                let statements =
                  let open Expression in
                  let matches_removed_platform left right =
                    let is_platform expression = Expression.show expression = "sys.platform" in
                    let is_win32 { Node.value; _ } =
                      match value with
                      | String { StringLiteral.value; _ } ->
                          value = "win32"
                      | _ ->
                          false
                    in
                    (is_platform left && is_win32 right) or (is_platform right && is_win32 left)
                  in
                  match test with
                  | ComparisonOperator {
                      ComparisonOperator.left;
                      operator;
                      right;
                    } when matches_removed_platform left right ->
                      begin
                        match operator with
                        | ComparisonOperator.Equals
                        | Is ->
                            orelse
                        | NotEquals
                        | IsNot ->
                            body
                        | _ ->
                            [statement]
                      end
                  | _ ->
                      [statement]
                in
                if not (List.is_empty statements) then
                  statements
                else
                  [Node.create ~location Statement.Pass]
              in
              (), statements
            end
        | _ ->
            (), [statement]
    end)
  in
  Transform.transform () source
  |> Transform.source


let expand_type_checking_imports source =
  let module Transform = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = unit

      let statement _ ({ Node.value; _ } as statement) =
        let is_type_checking { Node.value; _ } =
          match value with
          | Access (SimpleAccess [Access.Identifier "typing"; Access.Identifier "TYPE_CHECKING"])
          | Access (SimpleAccess [Access.Identifier "TYPE_CHECKING"]) ->
              true
          | _ ->
              false
        in
        match value with
        | If { If.test; body; _ } when is_type_checking test ->
            (), body
        | _ ->
            (), [statement]
    end)
  in
  Transform.transform () source
  |> Transform.source


let expand_wildcard_imports ~force source =
  let module Transform = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = unit

      let statement state ({ Node.value; _ } as statement) =
        match value with
        | Import { Import.from = Some from; imports }
          when List.exists ~f:(fun { Import.name; _ } -> Access.show name = "*") imports ->
            let expanded_import =
              match Ast.SharedMemory.Modules.get_exports ~qualifier:from with
              | Some exports ->
                  exports
                  |> List.map ~f:(fun name -> { Import.name; alias = None })
                  |> (fun expanded -> Import { Import.from = Some from; imports = expanded })
                  |> (fun value -> { statement with Node.value })
              | None ->
                  if force then
                    statement
                  else
                    raise MissingWildcardImport
            in
            state, [expanded_import]
        | _ ->
            state, [statement]
    end)
  in
  Transform.transform () source
  |> Transform.source


let expand_implicit_returns source =
  let module ExpandingTransform = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = unit

      let statement state statement =
        match statement with
        (* Insert implicit return statements at the end of function bodies. *)
        | { Node.location; value = Define define } ->
            let define =
              let has_yield =
                let module Visit = Visit.Make(struct
                    type t = bool

                    let expression sofar _ =
                      sofar

                    let statement sofar = function
                      | { Node.value = Statement.Yield _; _ } -> true
                      | { Node.value = Statement.YieldFrom _; _ } -> true
                      | _ -> sofar
                  end)
                in
                Visit.visit false (Source.create define.Define.body)
              in
              let has_return_in_finally =
                match List.last define.Define.body with
                | Some { Node.value = Try { Try.finally; _ }; _ } ->
                    begin
                      match List.last finally with
                      | Some { Node.value = Return _; _ } ->
                          true
                      | _ ->
                          false
                    end
                | _ ->
                    false
              in
              let loops_forever =
                match List.last define.Define.body with
                | Some { Node.value = While { While.test = { Node.value = True; _ }; _ }; _ } ->
                    true
                | _ ->
                    false
              in
              if has_yield || has_return_in_finally || loops_forever then
                define
              else
                match List.last define.Define.body with
                | Some { Node.value = Return _; _ } ->
                    define
                | Some statement ->
                    {
                      define with
                      Define.body = define.Define.body @ [{
                          Node.location = statement.Node.location;
                          value = Return { Return.expression = None; is_implicit = true };
                        }];
                    }
                | _ ->
                    define
            in
            state,
            [{ Node.location; value = Define define }]
        | _ ->
            state, [statement]
    end)
  in
  ExpandingTransform.transform () source
  |> ExpandingTransform.source


let defines
    ?(include_stubs = false)
    ?(include_nested = false)
    ?(extract_into_toplevel = false)
    ({ Source.qualifier; statements; _ } as source) =

  let module Collector = Visit.StatementCollector(struct
      type t = Define.t Node.t

      let visit_children = function
        | { Node.value = Define _; _ } -> include_nested
        | _ -> true

      let predicate = function
        | { Node.location; value = Define define } when Define.is_stub define ->
            if include_stubs then
              Some ({ Node.location; Node.value = define })
            else
              None
        | { Node.location; value = Define define } ->
            Some ({ Node.location; Node.value = define })
        | _ ->
            None
    end)
  in
  let defines = (Collector.collect source) in
  if extract_into_toplevel then
    let toplevel =
      Node.create_with_default_location
        (Statement.Define.create_toplevel ~qualifier:(Some qualifier) ~statements)
    in
    toplevel :: defines
  else
    defines


let classes source =
  let module Collector = Visit.StatementCollector(struct
      type t = Statement.Class.t Node.t

      let visit_children _ =
        true

      let predicate = function
        | { Node.location; value = Class class_define } ->
            Some ({ Node.location; Node.value = class_define })
        | _ ->
            None
    end)
  in
  Collector.collect source


let dequalify_map source =
  let module ImportDequalifier = Transform.MakeStatementTransformer(struct
      include Transform.Identity
      type t = Access.t Access.Map.t

      let statement map ({ Node.value; _ } as statement) =
        match value with
        | Import { Import.from = None; imports } ->
            let add_import map { Import.name; alias } =
              match alias with
              | Some alias ->
                  (* Add `name -> alias`. *)
                  Map.set map ~key:(List.rev name) ~data:alias
              | None ->
                  map
            in
            List.fold_left imports ~f:add_import ~init:map,
            [statement]
        | Import { Import.from = Some from; imports } ->
            let add_import map { Import.name; alias } =
              match alias with
              | Some alias ->
                  (* Add `alias -> from.name`. *)
                  Map.set map ~key:(List.rev (from @ name)) ~data:alias
              | None ->
                  (* Add `name -> from.name`. *)
                  Map.set map ~key:(List.rev (from @ name)) ~data:name
            in
            List.fold_left imports ~f:add_import ~init:map,
            [statement]
        | _ ->
            map, [statement]
    end)
  in
  (* Note that map keys are reversed accesses because it makes life much easier in dequalify *)
  let qualifier = Reference.access source.Source.qualifier in
  let map = Map.set ~key:(List.rev qualifier) ~data:[] Access.Map.empty in
  ImportDequalifier.transform map source
  |> fun { ImportDequalifier.state; _ } -> state


let replace_mypy_extensions_stub ({ Source.handle; statements; _ } as source) =
  if String.is_suffix (File.Handle.show handle) ~suffix:"mypy_extensions.pyi" then
    let typed_dictionary_stub ~location =
      let node value = Node.create ~location value in
      Assign {
        target = node (Access (SimpleAccess (Access.create "TypedDict")));
        annotation = Some (node (Access (SimpleAccess (Access.create "typing._SpecialForm"))));
        value = node Ellipsis;
        parent = None;
      } |> node
    in
    let replace_typed_dictionary_define = function
      | { Node.location; value = Define { name; _ } } when Reference.show name = "TypedDict" ->
          typed_dictionary_stub ~location
      | statement ->
          statement
    in
    { source with statements = List.map ~f:replace_typed_dictionary_define statements }
  else
    source


let expand_typed_dictionary_declarations ({ Source.statements; qualifier; _ } as source) =
  let expand_typed_dictionaries ({ Node.location; value } as statement) =
    let expanded_declaration =
      let typed_dictionary_declaration_assignment ~name ~fields ~target ~parent ~total =
        let arguments =
          let fields =
            let tuple (key, value) = Node.create (Expression.Tuple [key; value]) ~location in
            List.map fields ~f:tuple
          in
          let total =
            Node.create (if total then Expression.True else Expression.False) ~location
          in
          [{
            Argument.name = None;
            value = Node.create (Expression.Tuple (name :: total :: fields)) ~location;
          }]
        in
        let access =
          Access
            (SimpleAccess [
                Access.Identifier "mypy_extensions";
                Access.Identifier "TypedDict";
                Access.Identifier "__getitem__";
                Access.Call (Node.create arguments ~location);
              ]);
        in
        let annotation =
          let node value = Node.create value ~location in
          Access
            (SimpleAccess [
                Access.Identifier "typing";
                Access.Identifier "Type";
                Access.Identifier "__getitem__";
                Access.Call
                  (node [{ Expression.Record.Argument.name = None; value = node access }]);
              ])
          |> node
          |> Option.some
        in
        let access = Node.create access ~location in
        Assign {
          target;
          annotation;
          value = access;
          parent;
        };
      in
      let is_typed_dictionary ~module_name ~typed_dictionary =
        module_name = "mypy_extensions" &&
        typed_dictionary = "TypedDict"
      in
      let extract_totality arguments =
        let is_total ~total = Identifier.sanitized total = "total" in
        List.find_map arguments ~f:(function
            | {
              Argument.name = Some { value = total; _ };
              value = { Node.value = Expression.True; _ }
            } when is_total ~total ->
                Some true
            | {
              Argument.name = Some { value = total; _ };
              value = { Node.value = Expression.False; _ }
            } when is_total ~total ->
                Some false
            | _ ->
                None)
        |> Option.value ~default:true
      in
      match value with
      | Assign {
          target;
          value = {
            Node.value =
              Access
                (SimpleAccess [
                    Access.Identifier module_name;
                    Access.Identifier typed_dictionary;
                    Access.Call {
                      Node.value =
                        { Argument.name = None; value = name }
                        :: {
                          Argument.name = None;
                          value = { Node.value = Dictionary { Dictionary.entries; _ }; _};
                          _;
                        }
                        :: argument_tail;
                      _;
                    };
                  ]);
            _;
          };
          parent;
          _;
        }
        when is_typed_dictionary ~module_name ~typed_dictionary ->
          typed_dictionary_declaration_assignment
            ~name
            ~fields:(List.map entries ~f:(fun { Dictionary.key; value } -> key, value))
            ~target
            ~parent
            ~total:(extract_totality argument_tail)
      | Class {
          name = class_name;
          bases =
            {
              Argument.name = None;
              value = {
                Node.value =
                  Access
                    (SimpleAccess [
                        Access.Identifier module_name;
                        Access.Identifier typed_dictionary;
                      ]);
                _;
              };
            } :: bases_tail;
          body;
          decorators = _;
          docstring = _;
        }
        when is_typed_dictionary ~module_name ~typed_dictionary ->
          let string_literal identifier =
            Expression.String { value = identifier; kind = StringLiteral.String }
            |> Node.create ~location
          in
          let fields =
            let extract = function
              | {
                Node.value =
                  Assign {
                    target = { Node.value = Access (SimpleAccess name); _ };
                    annotation = Some annotation;
                    value = { Node.value = Ellipsis; _ };
                    parent = _;
                  };
                _;
              } ->
                  Reference.drop_prefix ~prefix:class_name (Reference.from_access name)
                  |> Reference.single
                  >>| (fun name -> string_literal name, annotation)
              | _ ->
                  None
            in
            List.filter_map body ~f:extract
          in
          let declaration class_name =
            let qualified =
              qualify_local_identifier class_name ~qualifier:(Reference.access qualifier)
            in
            typed_dictionary_declaration_assignment
              ~name:(string_literal class_name)
              ~fields
              ~target:(Node.create (Access (SimpleAccess qualified)) ~location)
              ~parent:None
              ~total:(extract_totality bases_tail)
          in
          Reference.drop_prefix ~prefix:qualifier class_name
          |> Reference.single
          >>| declaration
          |> Option.value ~default:value
      | _ ->
          value
    in
    { statement with Node.value = expanded_declaration }
  in
  { source with Source.statements = List.map ~f:expand_typed_dictionaries statements }


let preprocess_steps ~force source =
  source
  |> expand_relative_imports
  |> expand_string_annotations
  |> expand_format_string
  |> replace_platform_specific_code
  |> replace_version_specific_code
  |> expand_type_checking_imports
  |> expand_wildcard_imports ~force
  |> qualify
  |> expand_implicit_returns
  |> replace_mypy_extensions_stub
  |> expand_typed_dictionary_declarations


let preprocess source =
  preprocess_steps ~force:true source


let try_preprocess source =
  match preprocess_steps ~force:false source with
  | source ->
      Some source
  | exception MissingWildcardImport ->
      None
