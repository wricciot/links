(*****************************************************************************
 ** simpleSqlGen.ml - Simple Sql syntax generator                           **
 **                                                                         **
 ** author: Wilmer Ricciotti                                                **
 *****************************************************************************)

open Utility
open CommonTypes

module Q = Query.Lang
module C = Constant
module S = Sql

let mapstrcat sep f l = l |> List.map f |> String.concat sep

(* convert an NRC-style query into an SQL-style query *)
let rec sql_of_query is_set = function
| Q.Concat ds -> S.Union (is_set, List.map (disjunct is_set) ds, 0)
| q -> disjunct is_set q

and disjunct is_set = function
| Q.Prom p -> sql_of_query true p
| Q.For (_, gs, os, j) ->
    let _, froms =
        List.fold_left (fun (locvars,acc) (v,_q as g) -> (v::locvars, generator locvars g::acc)) ([],[]) gs
    in
    let os = List.map base_exp os in
    let selects, where = body j in
    S.Select (is_set, (selects, List.rev froms, where, os))
| _ -> failwith "disjunct"

and generator locvars = function
| (v, Q.Prom p) -> (S.FromQuery (Q.contains_free locvars p, sql_of_query true p), v)
| (v, Q.Table (_, tname, _, _)) -> (S.FromTable tname, v)
| (v, Q.Dedup (Q.Table (_, tname, _, _))) -> (S.FromDedupTable tname, v)
| _ -> failwith "generator"

and body = function
| Q.Singleton (Q.Record fields) ->
    (List.map (fun (f,x) -> (base_exp x, f)) (StringMap.to_alist fields), Sql.Constant (Constant.Bool true))
| Q.If (c, Q.Singleton (Q.Record fields), Q.Concat []) -> 
    let c' = base_exp c in
    let t = List.map (fun (f,x) -> (base_exp x, f)) (StringMap.to_alist fields) in
    (t, c')
| _ -> failwith "body"

and base_exp = function
(* XXX: Project expects a (numbered) var, but we have a table name 
   so I'll make an act of faith and believe that we never project from tables, but only from variables *)
(* | Q.Project (Q.Table (_, n, _, _), l) -> S.Project (n,l) *)
| Q.Project (Q.Var (n,_), l) -> S.Project (n,l)
| Q.If (c, t, e) -> S.Case (base_exp c, base_exp t, base_exp e)
| Q.Apply (Q.Primitive "tilde", [s; r]) ->
    begin
    match Query.likeify r with
        | Some r ->
        S.Apply ("LIKE", [base_exp s; Sql.Constant (Constant.String r)])
        | None ->
        let r =
                (* HACK:

                    this only works if the regexp doesn't include any variables bound by the query
                *)
                S.Constant (Constant.String (Regex.string_of_regex (Linksregex.Regex.ofLinks (Q.value_of_expression r))))
            in
                Sql.Apply ("RLIKE", [base_exp s; r])
    end
| Q.Apply (Q.Primitive "Empty", [v]) -> S.Empty (sql_of_query false v)
| Q.Apply (Q.Primitive "length", [v]) -> S.Length (sql_of_query false v)
| Q.Apply (Q.Primitive f, vs) -> S.Apply (f, List.map base_exp vs)
| Q.Constant c -> S.Constant c
(* WR: we don't support indices in this simple Sql generator *)
(* | Q.Primitive "index" -> ??? *)
| e ->
    Debug.print ("Not a base expression: " ^ (Q.show e) ^ "\n");
    failwith "base_exp"