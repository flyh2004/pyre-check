(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Statement
open TypeCheck

open Test

module Parallel = Hack_parallel.Std
module TestSetup = AnalysisTestSetup


let parse_source ?(qualifier=[]) source =
  parse ~qualifier source
  |> Preprocessing.preprocess


let check_source source =
  let configuration = TestSetup.configuration in
  let environment = TestSetup.environment ~configuration () in
  Service.Environment.populate environment [source];
  check configuration environment source |> ignore


let assert_call_graph source ~expected =
  let source = parse_source source in
  let configuration = TestSetup.configuration in
  let environment = TestSetup.environment ~configuration () in
  Service.Environment.populate environment [source];
  check configuration environment source |> ignore;
  let call_graph = Analysis.CallGraph.create ~environment ~source in
  let result =
    let fold_call_graph ~key:caller ~data:callees result =
      let callee = List.hd_exn callees in
      Format.sprintf
        "%s -> %s\n%s"
        (Access.show caller)
        (Access.show callee)
        result
    in
    Access.Map.fold call_graph ~init:"" ~f:fold_call_graph
  in
  let expected = expected ^ "\n" in
  assert_equal ~printer:ident result expected


let test_construction _ =
  assert_call_graph
    {|
    class Foo:
      def __init__(self):
        pass

      def bar(self):
        return 10

      def quux(self):
        return self.bar()
    |}
    ~expected:"Foo.quux -> Foo.bar";

  assert_call_graph
    {|
    class Foo:
      def __init__(self):
        pass

      def bar(self):
        return self.quux()

      def quux(self):
        return self.bar()
    |}
    ~expected:
      "Foo.quux -> Foo.bar\n\
       Foo.bar -> Foo.quux";

  assert_call_graph
    {|
     class A:
       def __init__(self) -> A:
         return self

     class B:
       def __init__(self) -> A:
         return A()
     |}
    ~expected:
      "B.__init__ -> A.__init__"


let test_type_collection _ =
  let open TypeResolutionSharedMemory in
  let assert_type_collection source ~qualifier ~expected =
    let source = parse_source ~qualifier source in
    let configuration = TestSetup.configuration in
    let environment = TestSetup.environment ~configuration () in
    Service.Environment.populate environment [source];
    check configuration environment source |> ignore;
    let defines =
      Preprocessing.defines source
      |> List.map ~f:(fun define -> define.Node.value)
    in
    let Define.{ name; body = statements; _ } = List.nth_exn defines 1 in
    let lookup =
      let build_lookup lookup { key; annotations } =
        Int.Map.set lookup ~key ~data:annotations in
      TypeResolutionSharedMemory.get name
      |> (fun value -> Option.value_exn value)
      |> List.fold ~init:Int.Map.empty ~f:build_lookup
    in
    let test_expect (node_id, statement_index, test_access, expected_type) =
      let key = [%hash: int * int] (node_id, statement_index) in
      let test_access = Access.create test_access in
      let annotations =
        Int.Map.find_exn lookup key
        |> Access.Map.of_alist_exn
      in
      let resolution = Environment.resolution environment ~annotations () in
      let statement = List.nth_exn statements statement_index in
      Visit.collect_accesses_with_location statement
      |> List.hd_exn
      |> fun { Node.value = access; _ } ->
      if String.equal (Access.show access) (Access.show test_access) then
        let open Annotated in
        let open Access.Element in
        let last_element =
          Annotated.Access.create access
          |>  Annotated.Access.last_element ~resolution
        in
        match last_element with
        | Signature {
            signature =
              Signature.Found {
                Signature.callable = {
                  Type.Callable.kind = Type.Callable.Named callable_type;
                  _;
                };
                _;
              };
            _;
          } ->
            assert_equal (Expression.Access.show callable_type) expected_type
        | _ ->
            assert false
    in
    List.iter expected ~f:test_expect

  in
  assert_type_collection
    {|
        class A:
          def foo(self) -> int:
            return 1

        class B:
          def foo(self) -> int:
            return 2

        class X:
          def caller(self):
            a = A()
            a.foo()
            a = B()
            a.foo()
        |}
    ~qualifier:(Access.create "test1")
    ~expected:
      [
        (5, 1, "$local_0$a.foo.(...)", "test1.A.foo");
        (5, 3, "$local_0$a.foo.(...)", "test1.B.foo")
      ];

  assert_type_collection
    {|
       class A:
         def foo(self) -> int:
           return 1

       class B:
         def foo(self) -> A:
           return A()

       class X:
         def caller(self):
           a = B().foo().foo()
    |}
    ~qualifier:(Access.create "test2")
    ~expected:[(5, 0, "$local_0$a.foo.(...).foo.(...)", "test2.A.foo")]



let test_method_overrides _ =
  let assert_method_overrides source ~expected =
    let expected =
      let create_accesses (access, accesses) =
        Access.create access, List.map accesses ~f:Access.create
      in
      List.map expected ~f:create_accesses
    in
    let source = parse_source source in
    let configuration = TestSetup.configuration in
    let environment = TestSetup.environment ~configuration () in
    Service.Environment.populate environment [source];
    let overrides_map = Service.Analysis.overrides_of_source environment source in
    let expected_overrides = Access.Map.of_alist_exn expected in
    let equal_elements = List.equal ~equal:Access.equal in
    assert_equal
      ~cmp:(Access.Map.equal equal_elements)
      overrides_map
      expected_overrides
  in
  assert_method_overrides
    {|
      class Foo:
        def foo(): pass
      class Bar(Foo):
        def foo(): pass
      class Baz(Bar):
        def foo(): pass
        def baz(): pass
      class Quux(Foo):
        def foo(): pass
    |}
    ~expected:
      [
        "Bar.foo", ["Baz.foo"];
        "Foo.foo", ["Bar.foo"; "Quux.foo"]
      ]


let test_strongly_connected_components _ =
  let assert_strongly_connected_components source ~qualifier ~expected =
    let qualifier = Access.create qualifier in
    let expected = List.map expected ~f:(List.map ~f:Access.create) in
    let source = parse_source ~qualifier source in
    let configuration = TestSetup.configuration in
    let environment = TestSetup.environment ~configuration () in
    Service.Environment.populate environment [source];
    check configuration environment source |> ignore;
    let partitions =
      let edges = CallGraph.create ~environment ~source in
      CallGraph.partition ~edges
    in
    let printer partitions = Format.asprintf "%a" CallGraph.pp_partitions partitions in
    assert_equal ~printer partitions expected
  in

  assert_strongly_connected_components
    {|
    class Foo:
      def __init__(self):
        pass

      def c1(self):
        return self.c1()

      def c2(self):
        return self.c1()
    |}
    ~qualifier:"s0"
    ~expected:
      [
        ["s0.Foo.c1"];
        ["s0.Foo.c2"];
      ];

  assert_strongly_connected_components
    {|
    class Foo:
      def __init__(self):
        pass

      def c1(self):
        return self.c2()

      def c2(self):
        return self.c1()

      def c3(self):
        return self.c4()

      def c4(self):
        return self.c3()

      def c5(self):
        return self.c5()
    |}
    ~qualifier:"s1"
    ~expected:
      [
        ["s1.Foo.c3"; "s1.Foo.c4"];
        ["s1.Foo.c2"; "s1.Foo.c1"];
        ["s1.Foo.c5"];
      ];

  assert_strongly_connected_components
    {|
    class Foo:
      def __init__(self):
        pass

      def c1(self):
        return self.c2()

      def c2(self):
        return self.c1()

      def c3(self):
        b = Bar()
        return b.c2()

    class Bar:
      def __init__(self):
        pass

      def c1(self):
        f = Foo()
        return f.c1()

      def c2(self):
        f = Foo()
        return f.c3()
    |}
    ~qualifier:"s2"
    ~expected:
      [
        ["s2.Foo.c1"; "s2.Foo.c2"];
        ["s2.Foo.__init__"];
        ["s2.Bar.c1"];
        ["s2.Bar.__init__"];
        ["s2.Bar.c2"; "s2.Foo.c3"];
      ]


let () =
  Parallel.Daemon.check_entry_point ();
  "callGraph">:::[
    "type_collection">::test_type_collection;
    "build">::test_construction;
    "overrides">::test_method_overrides;
    "strongly_connected_components">::test_strongly_connected_components;
  ]
  |> run_test_tt_main