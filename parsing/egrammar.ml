(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id$ *)

open Pp
open Util
open Pcoq
open Extend
open Topconstr
open Genarg
open Libnames
open Nameops
open Tacexpr
open Names
open Vernacexpr

(**************************************************************************)
(*  
 * --- Note on the mapping of grammar productions to camlp4 actions ---
 *  
 * Translation of environments: a production
 *   [ nt1(x1) ... nti(xi) ] -> act(x1..xi)
 * is written (with camlp4 conventions):
 *   (fun vi -> .... (fun v1 -> act(v1 .. vi) )..)
 * where v1..vi are the values generated by non-terminals nt1..nti.
 * Since the actions are executed by substituting an environment,
 * the make_*_action family build the following closure:
 *
 *      ((fun env ->
 *          (fun vi -> 
 *             (fun env -> ...
 *           
 *                  (fun v1 ->
 *                     (fun env -> gram_action .. env act)
 *                     ((x1,v1)::env))
 *                  ...)
 *             ((xi,vi)::env)))
 *         [])
 *)

(**********************************************************************)
(** Declare Notations grammar rules                                   *)

type prod_item =
  | Term of Token.pattern
  | NonTerm of constr_production_entry * 
      (Names.identifier * constr_production_entry) option

type 'a action_env = (identifier * 'a) list

let make_constr_action
  (f : loc -> constr_expr action_env -> constr_expr) pil =
  let rec make (env : constr_expr action_env) = function
    | [] ->
	Gramext.action (fun loc -> f loc env)
    | None :: tl -> (* parse a non-binding item *)
        Gramext.action (fun _ -> make env tl)
    | Some (p, (ETConstr _| ETOther _)) :: tl -> (* constr non-terminal *)
        Gramext.action (fun (v:constr_expr) -> make ((p,v) :: env) tl)
    | Some (p, ETReference) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:reference) -> make ((p,CRef v) :: env) tl)
    | Some (p, ETIdent) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:identifier) ->
	  make ((p,CRef (Ident (dummy_loc,v))) :: env) tl)
    | Some (p, ETBigint) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:Bigint.bigint) ->
	  make ((p,CPrim (dummy_loc,Numeral v)) :: env) tl)
    | Some (p, ETConstrList _) :: tl ->
        Gramext.action (fun (v:constr_expr list) ->
          let dummyid = Ident (dummy_loc,id_of_string "") in
	  make ((p,CAppExpl (dummy_loc,(None,dummyid),v)) :: env) tl)
    | Some (p, ETPattern) :: tl -> 
	failwith "Unexpected entry of type cases pattern" in
  make [] (List.rev pil)

let make_cases_pattern_action
  (f : loc -> cases_pattern_expr action_env -> cases_pattern_expr) pil =
  let rec make (env : cases_pattern_expr action_env) = function
    | [] ->
	Gramext.action (fun loc -> f loc env)
    | None :: tl -> (* parse a non-binding item *)
        Gramext.action (fun _ -> make env tl)
    | Some (p, ETConstr _) :: tl -> (* pattern non-terminal *)
        Gramext.action (fun (v:cases_pattern_expr) -> make ((p,v) :: env) tl)
    | Some (p, ETReference) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:reference) ->
	  make ((p,CPatAtom (dummy_loc,Some v)) :: env) tl)
    | Some (p, ETIdent) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:identifier) ->
	  make ((p,CPatAtom (dummy_loc,Some (Ident (dummy_loc,v)))) :: env) tl)
    | Some (p, ETBigint) :: tl -> (* non-terminal *)
        Gramext.action (fun (v:Bigint.bigint) ->
	  make ((p,CPatPrim (dummy_loc,Numeral v)) :: env) tl)
    | Some (p, ETConstrList _) :: tl ->
        Gramext.action (fun (v:cases_pattern_expr list) ->
          let dummyid = Ident (dummy_loc,id_of_string "") in
	  make ((p,CPatCstr (dummy_loc,dummyid,v)) :: env) tl)
    | Some (p, (ETPattern | ETOther _)) :: tl -> 
	failwith "Unexpected entry of type cases pattern or other" in
  make [] (List.rev pil)

let make_constr_prod_item univ assoc from forpat = function
  | Term tok -> (Gramext.Stoken tok, None)
  | NonTerm (nt, ovar) ->
      let eobj = symbol_of_production assoc from forpat nt in
      (eobj, ovar)

let extend_constr entry (n,assoc,pos,p4assoc,name) mkact (forpat,pt) =
  let univ = get_univ "constr" in
  let pil = List.map (make_constr_prod_item univ assoc n forpat) pt in
  let (symbs,ntl) = List.split pil in
  grammar_extend entry pos [(name, p4assoc, [symbs, mkact ntl])]

let extend_constr_notation (n,assoc,ntn,rule) =
  (* Add the notation in constr *)
  let mkact loc env = CNotation (loc,ntn,List.map snd env) in
  let (e,level,keepassoc) = get_constr_entry false (ETConstr (n,())) in
  let pos,p4assoc,name = find_position false keepassoc assoc level in
  extend_constr e (ETConstr(n,()),assoc,pos,p4assoc,name)
    (make_constr_action mkact) (false,rule);
  (* Add the notation in cases_pattern *)
  let mkact loc env = CPatNotation (loc,ntn,List.map snd env) in
  let (e,level,keepassoc) = get_constr_entry true (ETConstr (n,())) in
  let pos,p4assoc,name = find_position true keepassoc assoc level in
  extend_constr e (ETConstr (n,()),assoc,pos,p4assoc,name)
    (make_cases_pattern_action mkact) (true,rule)

(**********************************************************************)
(** Making generic actions in type generic_argument                   *)

let make_generic_action
  (f:loc -> ('b * raw_generic_argument) list -> 'a) pil =
  let rec make env = function
    | [] -> 
	Gramext.action (fun loc -> f loc env)
    | None :: tl -> (* parse a non-binding item *)
        Gramext.action (fun _ -> make env tl)
    | Some (p, t) :: tl -> (* non-terminal *)
        Gramext.action (fun v -> make ((p,in_generic t v) :: env) tl) in
  make [] (List.rev pil)

let make_rule univ f g pt =
  let (symbs,ntl) = List.split (List.map g pt) in
  let act = make_generic_action f ntl in
  (symbs, act)

(**********************************************************************)
(** Grammar extensions declared at ML level                           *) 

type grammar_tactic_production =
  | TacTerm of string
  | TacNonTerm of
      loc * (Gram.te Gramext.g_symbol * argument_type) * string option

let make_prod_item = function
  | TacTerm s -> (Gramext.Stoken (Lexer.terminal s), None)
  | TacNonTerm (_,(nont,t), po) -> (nont, option_map (fun p -> (p,t)) po)

(* Tactic grammar extensions *)

let tac_exts = ref []
let get_extend_tactic_grammars () = !tac_exts

let extend_tactic_grammar s gl =
  tac_exts := (s,gl) :: !tac_exts;
  let univ = get_univ "tactic" in
  let mkact loc l = Tacexpr.TacExtend (loc,s,List.map snd l) in
  let rules = List.map (make_rule univ mkact make_prod_item) gl in
  Gram.extend Tactic.simple_tactic None [(None, None, List.rev rules)]

(* Vernac grammar extensions *)

let vernac_exts = ref []
let get_extend_vernac_grammars () = !vernac_exts

let extend_vernac_command_grammar s gl =
  vernac_exts := (s,gl) :: !vernac_exts;
  let univ = get_univ "vernac" in
  let mkact loc l = VernacExtend (s,List.map snd l) in
  let rules = List.map (make_rule univ mkact make_prod_item) gl in
  Gram.extend Vernac_.command None [(None, None, List.rev rules)]

(**********************************************************************)
(** Grammar declaration for Tactic Notation (Coq level)               *) 

(* Interpretation of the grammar entry names *)

let find_index s t =
  let t,n = repr_ident (id_of_string t) in
  if s <> t or n = None then raise Not_found;
  out_some n

let rec interp_entry_name up_level s =
  let l = String.length s in
  if l > 8 & String.sub s 0 3 = "ne_" & String.sub s (l-5) 5 = "_list" then
    let t, g = interp_entry_name up_level (String.sub s 3 (l-8)) in
    List1ArgType t, Gramext.Slist1 g
  else if l > 5 & String.sub s (l-5) 5 = "_list" then
    let t, g = interp_entry_name up_level (String.sub s 0 (l-5)) in
    List0ArgType t, Gramext.Slist0 g
  else if l > 4 & String.sub s (l-4) 4 = "_opt" then
    let t, g = interp_entry_name up_level (String.sub s 0 (l-4)) in
    OptArgType t, Gramext.Sopt g
  else
    let s = if s = "hyp" then "var" else s in
    try 
      let i = find_index "tactic" s in
      ExtraArgType s, 
      if i=up_level then Gramext.Sself else
      if i=up_level-1 then Gramext.Snext else
      Gramext.Snterml(Pcoq.Gram.Entry.obj Tactic.tactic_expr,string_of_int i)
    with Not_found ->
    let e = 
      (* Qualified entries are no longer in use *)
      try get_entry (get_univ "tactic") s
      with _ -> 
      try get_entry (get_univ "prim") s
      with _ ->
      try get_entry (get_univ "constr") s
      with _ -> error ("Unknown entry "^s)
    in
    let o = object_of_typed_entry e in
    let t = type_of_typed_entry e in
    t,Gramext.Snterm (Pcoq.Gram.Entry.obj o)

let make_vprod_item n = function
  | VTerm s -> (Gramext.Stoken (Lexer.terminal s), None)
  | VNonTerm (loc, nt, po) ->
      let (etyp, e) = interp_entry_name n nt in
      e, option_map (fun p -> (p,etyp)) po

let get_tactic_entry n =
  if n = 0 then
    weaken_entry Tactic.simple_tactic, None
  else if 1<=n && n<=5 then
    weaken_entry Tactic.tactic_expr, Some (Gramext.Level (string_of_int n))
  else 
    error ("Invalid Tactic Notation level: "^(string_of_int n))

(* Declaration of the tactic grammar rule *)

let head_is_ident = function VTerm _::_ -> true | _ -> false

let add_tactic_entry (key,lev,prods,tac) =
  let univ = get_univ "tactic" in
  let entry, pos = get_tactic_entry lev in
  let mkprod = make_vprod_item lev in
  let rules = 
    if lev = 0 then begin
      if not (head_is_ident prods) then
	error "Notation for simple tactic must start with an identifier";
      let mkact s tac loc l =
	(TacAlias(loc,s,l,tac):raw_atomic_tactic_expr) in
      make_rule univ (mkact key tac) mkprod prods
    end
    else
      let mkact s tac loc l = 
	(TacAtom(loc,TacAlias(loc,s,l,tac)):raw_tactic_expr) in
      make_rule univ (mkact key tac) mkprod prods in
  let _ = find_position true true None None (* to synchronise with remove *) in
  grammar_extend entry pos [(None, None, List.rev [rules])]

(**********************************************************************)
(** State of the grammar extensions                                   *)

type notation_grammar = 
    int * Gramext.g_assoc option * notation * prod_item list

type all_grammar_command =
  | Notation of Notation.level * notation_grammar
  | TacticGrammar of
      (string * int * grammar_production list * 
        (Names.dir_path * Tacexpr.glob_tactic_expr))

let (grammar_state : all_grammar_command list ref) = ref []

let extend_grammar gram =
  (match gram with
  | Notation (_,a) -> extend_constr_notation a
  | TacticGrammar g -> add_tactic_entry g);
  grammar_state := gram :: !grammar_state

let reset_extend_grammars_v8 () =
  let te = List.rev !tac_exts in
  let tv = List.rev !vernac_exts in
  tac_exts := [];
  vernac_exts := [];
  List.iter (fun (s,gl) -> print_string ("Resinstalling "^s); flush stdout; extend_tactic_grammar s gl) te;
  List.iter (fun (s,gl) -> extend_vernac_command_grammar s gl) tv

let recover_notation_grammar ntn prec =
  let l = map_succeed (function
    | Notation (prec',(_,_,ntn',_ as x)) when prec = prec' & ntn = ntn' -> x
    | _ -> failwith "") !grammar_state in
  assert (List.length l = 1);
  List.hd l

(* Summary functions: the state of the lexer is included in that of the parser.
   Because the grammar affects the set of keywords when adding or removing
   grammar rules. *)
type frozen_t = all_grammar_command list * Lexer.frozen_t

let freeze () = (!grammar_state, Lexer.freeze ())

(* We compare the current state of the grammar and the state to unfreeze, 
   by computing the longest common suffixes *)
let factorize_grams l1 l2 =
  if l1 == l2 then ([], [], l1) else list_share_tails l1 l2

let number_of_entries gcl =
  List.fold_left
    (fun n -> function
      | Notation _ -> n + 2 (* 1 for operconstr, 1 for pattern *)
      | TacticGrammar _ -> n + 1)
    0 gcl

let unfreeze (grams, lex) =
  let (undo, redo, common) = factorize_grams !grammar_state grams in
  let n = number_of_entries undo in
  remove_grammars n;
  remove_levels n;
  grammar_state := common;
  Lexer.unfreeze lex;
  List.iter extend_grammar (List.rev redo)
 
let init_grammar () =
  remove_grammars (number_of_entries !grammar_state);
  grammar_state := []

let init () =
  init_grammar ()

open Summary

let _ = 
  declare_summary "GRAMMAR_LEXER"
    { freeze_function = freeze;
      unfreeze_function = unfreeze;
      init_function = init;
      survive_module = false;
      survive_section = false }
