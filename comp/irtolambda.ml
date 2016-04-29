(*pp deriving *)
(* Translation of Links IR into OCaml Lambda IR *)
open Utility


let ocaml_function module_name function_name = (module_name, function_name)
	         	   
let ocaml_of_links_function f =
  let stdlib = "Pervasives" in
  let listlib = "List" in
  (* Links function, (module name, ocaml function) *)
  List.assoc f
	     [   "print", ocaml_function stdlib "print_endline"
	       ; "intToString", ocaml_function stdlib "string_of_int"
	       ; "floatToString", ocaml_function stdlib "string_of_float"
	       ; "^^", ocaml_function stdlib "^"
	       ; "hd", ocaml_function listlib "hd"
	       ; "tl", ocaml_function listlib "tl"
	     ]
       
let arith_ops =
  [ "+" 
  ; "-"
  ; "*"
  ; "/"
  ; "^"
  ; "mod"
  ; "+."
  ; "-."
  ; "*."
  ; "/."
  ; "^."
  ]

(*let string_ops =
  ["^^"] *)
    
let rel_ops =
  [ "=="
  ; "<>"
  ; "<"
  ; ">"
  ; "<="
  ; ">="
  ]
      
let is_arithmetic_operation : string -> bool =
  fun op -> List.mem op arith_ops
		     
let is_relational_operation : string -> bool =
  fun op -> List.mem op rel_ops


let primop   : string -> Lambda.primitive option =
  fun op ->
  let open Lambda in
  try 
    Some (
	if is_arithmetic_operation op then
	  match op with       
	  | "+" -> Paddint
	  | "-" -> Psubint
	  | "*" -> Pmulint
	  | "/" -> Pdivint
	  | "mod" -> Pmodint		 
	  | "+." -> Paddfloat
	  | "-." -> Psubfloat
	  | "*." -> Pmulfloat
	  | "/." -> Pdivfloat
	  | _ -> raise Not_found
	else if is_relational_operation op then   
	  Pintcomp (match op with
		    | "==" -> Ceq
		    | "<>" -> Cneq
		    | "<"  -> Clt
		    | ">"  -> Cgt
		    | "<=" -> Cle
		    | ">=" -> Cge
		    | _ -> raise Not_found)
	else raise Not_found
      )
  with
  | Not_found -> None
	       
let is_primitive   : Var.var -> bool = Lib.is_primitive_var
let primitive_name : Var.var -> string option =
  fun var ->
  try
    Some (Lib.primitive_name var)
  with
  | Not_found -> None
       
let translate (op_map,name_map) module_name ir =
  let open Lambda in
  let open LambdaDSL in
  let open Ir in
  let op_map =
    let dummy = -1 in
    let pos = ref dummy in
    StringMap.map (fun uid -> let _ = incr pos in (uid, !pos)) op_map
  in
  let get_op_uid label =
    try
      let (uid,_) = StringMap.find label op_map in
      Some uid
    with
    | Not_found -> None
  in
  let ident (var_name,uid) = create_ident var_name uid in
  let ident_of_var var =
    match IntMap.find var name_map with
    | name -> ident (name, var)
    | exception Not_found -> failwith ("Internal compiler failure: Cannot find name for var " ^ (string_of_int var))
  in
  let ident_of_binder b =
    let var = Var.var_of_binder b in
    match Var.name_of_binder b with
    | "" -> ident_of_var var
    | name -> ident (name, var)
  in
  let getglobal = lgetglobal (String.capitalize module_name) in
  let rec computation : computation -> lambda =
    fun (bs,tc) ->
    bindings bs (tail_computation tc)
  and tail_computation : tail_computation -> lambda =
    function
    | `Return v -> value v
    | `Special s -> special s       
    | `Apply (f, args) ->
       let args' =
	 if List.length args > 0 then
	   List.map value args
	 else
	   [lconst unit]
       in
       (* First, figure out whether f is primitive *)
       begin
	 match is_primitive_function f with
	 | None     -> lapply (value f) args'
	 | Some uid ->	    
	    (* Next, figure out which type of primitive f is *)
	    let fname =
	      match primitive_name uid with
	      | Some name -> name
	      | None -> failwith ("Internal compiler failure: Cannot find primitive name for var " ^ (string_of_int uid))
	    in
	    begin
	      match primop fname with
	      | Some instr -> lprim instr args'
	      | _ -> 
		 (* Must be Cons *)
		 begin
		   match fname with
		   | "Cons" -> lprim box args'
		   | "random" ->
		      let random = lookup "Random" "float" in
		      (lapply random [lfloat 1.0])
		   | _ ->
		      try
			let (module_name, fun_name) = ocaml_of_links_function fname in
			let f = lookup module_name fun_name in
			lapply f args'
		      with
		      | _ -> failwith ("Internal compiler failure: Unsupported primitive function " ^ fname)
		 end
	    end
       end
    | `If (cond, trueb, falseb) ->
       lif (value cond) (computation trueb) (computation falseb)
    | `Case (v, clauses, default) ->
       let v = value v in
       let default =
	 match default with
	 | None -> lapply (pervasives "failwith") [lstring "Pattern-matching failed"]
	 | Some (b,c) -> llet (ident_of_binder b) v (computation c)
       in
       let v'' = ident ("switch", Var.fresh_raw_var ()) in
       let switch_expr k =
	 llet v'' (lproject 0 v) k (* FIXME: assuming we always match on a "box" *)
       in
       switch_expr
	 (StringMap.fold
	    (fun v' (b,c) matchfail ->	     
	      lif (neq (lvar v'') (polyvariant v' None)) 
		  matchfail
		  (llet (ident_of_binder b) (lproject 1 v) (computation c))
	    ) clauses default
	 )    
    | _ -> assert false
  and special : special -> lambda =
    function
    | `Wrong _ -> lapply (pervasives "failwith") [lstring "Fatal error."]
    | `DoOperation (label, args, _) ->
       let perform label args =	 
	 lperform (lprim (field 0)
			 [ getglobal ])
		  [ lprim box args ]
       in
       let id =
	 match get_op_uid label with
	 | Some id -> id
	 | None    -> failwith ("Internal compiler failure: Cannot not find identifier for operation name " ^ label)
       in	 
    (*       lperform (ident (label, id)) (List.map value args) *)
(*       Lambda.(lprim (Pperform)
		     [ lprim (field 0)
		      [lprim (Lambda.Pgetglobal (Ident.create_persistent (String.capitalize module_name))) []]
                     ])*)
       perform label (List.map value args)
    | `Handle (v, clauses, _) ->
       let (value_clause, clauses) = StringMap.pop "Return" clauses in
       let value_handler =
	 let (b, comp) = value_clause in
	 lfun [ident_of_binder b] (computation comp)
       in
       let exn_handler =
	 let exn = ident ("exn", Var.fresh_raw_var ()) in	 
	 lfun [exn] (lraise Lambda.Raise_reraise (lvar exn))
       in
       let eff_handler =
	 let eff  = ident ("eff", Var.fresh_raw_var ()) in
	 let cont = ident ("cont", Var.fresh_raw_var ()) in
	 let forward =
	   ldelegate eff cont
	 in
	 let kid = ident ("_k", Var.fresh_raw_var ()) in
	 let k =
	   let param = ident ("param", Var.fresh_raw_var ()) in
	   lfun [param]
		(lapply (pervasives "continue") [lvar kid ; lvar param])
	 in
	 let bind_k scope =
	   llet ~kind:Alias
		kid
		(lprim (makeblock 0 Mutable) [lvar cont])
		scope
	 in
	 let rec take n xs =
	   if n <> 0 then
	     List.hd xs :: take (n-1) (List.tl xs)
	   else
	     []
	 in
	 let rec drop n xs =
	   if n <> 0 then
	     drop (n-1) (List.tl xs)
	   else
	     xs
	 in
	 let pop_k bs =
	   match List.length bs with
	   | 0 -> assert false
	   | 1 -> (List.hd bs, [])
	   | 2 -> (List.hd bs, List.tl bs)
	   | n -> (List.nth bs (n/2), (take ((n/2) - 1) bs) @ (drop ((n/2) + 1) bs))
	 in
	 let compile clauses =
	   StringMap.fold
	     (fun label (b,(bs,tc)) lam ->
(*	       let kid =
		 match List.hd (List.rev bs) with
		 | `Let ((uid,(_,name,_)),_) -> let _ = print_endline name in (name, uid)
		 | _ -> assert false
	       in
	       let bs = List.rev (List.tl (List.rev bs)) in*)
	       let (kb, bs) = pop_k bs in
	       let kid =
		 match kb with
		 | `Let ((uid,(_,name,_)),_) -> let _ = print_endline name in (name, uid)
		 | _ -> assert false
	       in
	       let clause body =
		 let bind_args_in body =
		   if List.length bs > 0 then
		     llet (ident_of_binder b)
			  (lproject 1 (lvar eff))
			  body
		   else
		     body
		 in
		 bind_args_in
		   (llet (ident kid)
			 k
			 body)
		      (*(llet (ident_of_binder b) (* bind b to *)
			    (lvar eff)
			    body)*)
	       in
	       let label =
		 match get_op_uid label with
		 | Some uid -> lvar (ident (label, uid))
		 | None -> failwith ("Internal compiler failure: Could not find unique identifier for operation " ^ label)
	       in
	       let effname = lproject 0 (lvar eff) in
	       (*lif (eq (lvar eff) label)*)
	       lif (eq effname (lprim (field 0) [ getglobal ]))
		   (clause (bindings bs (tail_computation tc)))
		   lam
	     )
	     clauses forward
	 in
	 lfun [eff ; cont] (bind_k (compile clauses))
       in
       let alloc_stack =
	 lalloc_stack
	   value_handler
	   exn_handler
	   eff_handler
       in
       let thunk =
	 let unit' = ident ("unit", Var.fresh_raw_var ()) in
	 lfun [unit'] (lapply (value v) [lconst unit])
       in
       lresume [ alloc_stack
	       ; thunk
	       ; lconst unit]
    | _ -> assert false
  and value : value -> lambda =
    function
    | `Constant c -> lconstant constant c
    | `Variable var ->
       if is_primitive var then
	 match primitive_name var with
	 | Some "Nil" -> lconst ff
	 | Some prim ->
	    let (module_name, fun_name) = ocaml_of_links_function prim in
	    lookup module_name fun_name
	 | Some "random" -> failwith "Random as a variable"
	 | None -> failwith ("Internal compiler failure: Cannot find primitive name for var " ^ (string_of_int var))
       else
	 lvar (ident_of_var var)
    | `TAbs (_, v)
    | `TApp (v, _) -> value v
    | `ApplyPure (f, args) -> tail_computation (`Apply (f, args))
    | `Inject (label, v, _) ->
       lpolyvariant label (Some [value v])
    | `Project (label, row) ->
       lproject ((int_of_string label)-1) (value row) (* FIXME: Assuming tuples! *)
    | `Extend (map, row) ->
       let vs = StringMap.to_list (fun _ v -> value v) map in
       begin
       match row with
       | Some r -> failwith "Internal compiler failure: Record extension not yet implemented."
       | None -> lprim box vs
       end
    | v -> failwith ("Internal compiler failure: Unimplemented feature:\n" ^ (Ir.Show_value.show v))
  and bindings : binding list -> (lambda -> lambda) =
    function
    | b :: bs -> fun k -> binding b (bindings bs k)
    | [] -> fun k -> k
  and binding : binding -> (lambda -> lambda) =
    let translate_fundef (_, (_, params, body), _, _) =
      let params' =
	if List.length params > 0 then
	  params
	else
	  [Var.fresh_unit_binder ()]
      in
      (lfun (List.map ident_of_binder params') (computation body))
    in
    fun b ->
    fun k ->
    match b with
    | `Let (b, (_, tc)) ->
       llet
	 (ident_of_binder b)
	 (tail_computation tc)
	 k
    | `Fun ((b, _, _, _) as f) ->
       llet
	 (ident_of_binder b)
	 (translate_fundef f)
	 k
    | `Rec funs ->
       let funs' =
	 List.fold_right
	   (fun ((b, _, _, _) as f) funs ->
	     (ident_of_binder b, translate_fundef f) :: funs)
	   funs []
       in
       lletrec funs' k
    | _ -> assert false
  and constant : Constant.constant -> structured_constant =
    function
    | `Int i      -> const_base int i
    | `Float f    -> const_base float f
    | `String s   -> string s
    | `Bool true  -> tt
    | `Bool false -> ff
    | _ -> assert false
  and is_primitive_function : value -> int option =
    function
    | `Variable var -> if is_primitive var then Some var else None
    | `TAbs (_,v) 
    | `TApp (v,_) -> is_primitive_function v
    | v -> failwith ("Internal compiler failure: Unknown, possibly primitive, node:\n " ^ (Show_value.show v))
  and program : program -> lambda =
    fun prog ->
    Compmisc.init_path false;
    Ident.reinit ();
    (** preamble: Declare operations **)
    let preamble =
      fun k ->
      (StringMap.fold
	 (fun label (uid,_) body ->
	   let efflabel = (String.capitalize module_name) ^ "." ^ label in
	   lseq
	     (llet (ident (label,uid))
		   (leffect efflabel)
		   (lprim (set_field_imm 0) [(lprim (Lambda.Pgetglobal (Ident.create_persistent (String.capitalize module_name))) []) ; lvar (ident (label,uid))]))
	     body
	 )
      ) op_map k
    in
(*    let ops = StringMap.fold
		(fun label (_,pos) xs -> (label,pos) :: xs) op_map []
		
    in*)
    let random_init k =
      let init = lookup "Random" "self_init" in
      llet (ident ("_rand_init", Var.fresh_raw_var ()))
	   (lapply init [lconst unit])
	   k
    in
    (** translate to lambda **)
    let exit_success = lconst ff in (* in this context "lconst ff" represents the exit code 0 *)
    lseq (preamble (random_init (computation prog))) exit_success
  in
  program ir
			    
let lambda_of_ir ((_,nenv,_) as envs) module_name prog =
  let maps =
    let gather = Gather.TraverseIr.gather prog in
    (gather#get_operation_env, Gather.TraverseIr.binders_map prog)
  in
  translate maps module_name prog
(*  let ir_translator = new translator (invert env) in
  ir_translator#program "Helloworld" prog*)
