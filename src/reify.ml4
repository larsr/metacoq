(*i camlp4deps: "parsing/grammar.cma" i*)
(*i camlp4use: "pa_extend.cmp" i*)

open Ltac_plugin

let contrib_name = "template-coq"

let toDecl (old: Names.name * ((Constr.constr) option) * Constr.constr) : Context.Rel.Declaration.t =
  let (name,value,typ) = old in 
  match value with
  | Some value -> Context.Rel.Declaration.LocalDef (name,value,typ)
  | None -> Context.Rel.Declaration.LocalAssum (name,typ)

let fromDecl (n: Context.Rel.Declaration.t) :  Names.name * ((Constr.constr) option) * Constr.constr =
  match n with 
  | Context.Rel.Declaration.LocalDef (name,value,typ) -> (name,Some value,typ)
  | Context.Rel.Declaration.LocalAssum (name,typ) -> (name,None,typ)

let cast_prop = ref (false)
let _ = Goptions.declare_bool_option {
  Goptions.optdepr = false;
  Goptions.optname = "Casting of propositions in template-coq";
  Goptions.optkey = ["Template";"Cast";"Propositions"];
  Goptions.optread = (fun () -> !cast_prop);
  Goptions.optwrite = (fun a -> cast_prop:=a);
}

(* whether Set Template Cast Propositions is on, as needed for erasure in Certicoq *)
let is_cast_prop () = !cast_prop                     
                     
let pp_constr fmt x = Pp.pp_with fmt (Printer.pr_constr x)

open Pp (* this adds the ++ to the current scope *)

exception NotSupported of Term.constr * string

let not_supported trm =
  (* Feedback.msg_error (str "Not Supported:" ++ spc () ++ Printer.pr_constr trm) ; *)
  CErrors.user_err (str "Not Supported:" ++ spc () ++ Printer.pr_constr trm)

let not_supported_verb trm rs =
  CErrors.user_err (str "Not Supported raised at " ++ str rs ++ str ":" ++ spc () ++ Printer.pr_constr trm)

let bad_term trm =
  raise (NotSupported (trm, "bad term"))

let bad_term_verb trm rs =
  raise (NotSupported (trm, "bad term because of " ^ rs))

let gen_constant_in_modules locstr dirs s =
  Universes.constr_of_global (Coqlib.gen_reference_in_modules locstr dirs s)

let opt_hnf_ctor_types = ref false
let opt_debug = ref false
              
let with_debug f =
  opt_debug := true ;
  try
    let result = f () in
    opt_debug := false ;
    result
  with
    e -> let _ = opt_debug := false in raise e

let debug (m : unit -> Pp.std_ppcmds) =
  if !opt_debug then
    Feedback.(msg_debug (m ()))
  else
    ()

let with_hnf_ctor_types f =
  opt_hnf_ctor_types := true ;
  try
    let result = f () in
    opt_hnf_ctor_types := false ;
    result
  with
    e -> let _ = opt_hnf_ctor_types := false in raise e

let hnf_type env ty =
  let rec hnf_type continue ty =
    match Term.kind_of_term ty with
      Term.Prod (n,t,b) -> Term.mkProd (n,t,hnf_type true b)
    | Term.LetIn _
      | Term.Cast _
      | Term.App _ when continue ->
       hnf_type false (Reduction.whd_all env ty)
    | _ -> ty
  in
  hnf_type true ty

let split_name s : (Names.DirPath.t * Names.Id.t) =
  let ss = List.rev (Str.split (Str.regexp (Str.quote ".")) s) in
  match ss with
    nm :: rst ->
     let dp = (Names.make_dirpath (List.map Names.id_of_string rst)) in (dp, Names.Id.of_string nm)
  | [] -> raise (Failure "Empty name cannot be quoted")

module Cmap = Names.KNmap
module Cset = Names.KNset
module Mindset = Names.Mindset

type ('a,'b) sum =
  Left of 'a | Right of 'b

module type Quoter = sig
  type t

  type quoted_ident
  type quoted_int
  type quoted_bool
  type quoted_name
  type quoted_sort
  type quoted_cast_kind
  type quoted_kernel_name
  type quoted_inductive
  type quoted_decl
  type quoted_program
  type quoted_univ_instance
  type quoted_mind_params
  type quoted_ind_entry =
    quoted_ident * t * quoted_bool * quoted_ident list * t list
  type quoted_definition_entry = t * t option
  type quoted_mind_entry
  type quoted_mind_finiteness
  type quoted_entry

  open Names

  val quote_ident : Id.t -> quoted_ident
  val quote_name : Name.t -> quoted_name
  val quote_int : int -> quoted_int
  val quote_bool : bool -> quoted_bool
  val quote_sort : Sorts.t -> quoted_sort
  val quote_cast_kind : Constr.cast_kind -> quoted_cast_kind
  val quote_kn : kernel_name -> quoted_kernel_name
  val quote_inductive : quoted_kernel_name * quoted_int -> quoted_inductive
  val quote_univ_instance : Univ.Instance.t -> quoted_univ_instance

  val quote_mind_params : (quoted_ident * (t,t) sum) list -> quoted_mind_params
  val quote_mind_finiteness : Decl_kinds.recursivity_kind -> quoted_mind_finiteness
  val quote_mutual_inductive_entry :
    quoted_mind_finiteness * quoted_mind_params * quoted_ind_entry list * quoted_bool ->
    quoted_mind_entry

  val quote_entry : (quoted_definition_entry, quoted_mind_entry) sum option -> quoted_entry

  val mkName : quoted_ident -> quoted_name
  val mkAnon : quoted_name

  val mkRel : quoted_int -> t
  val mkVar : quoted_ident -> t
  val mkSort : quoted_sort -> t
  val mkCast : t -> quoted_cast_kind -> t -> t
  val mkProd : quoted_name -> t -> t -> t
  val mkLambda : quoted_name -> t -> t -> t
  val mkLetIn : quoted_name -> t -> t -> t -> t
  val mkApp : t -> t array -> t
  val mkConst : quoted_kernel_name -> quoted_univ_instance -> t
  val mkInd : quoted_inductive -> quoted_univ_instance -> t
  val mkConstruct : quoted_inductive * quoted_int -> quoted_univ_instance -> t
  val mkCase : (quoted_inductive * quoted_int) -> quoted_int list -> t -> t ->
               t list -> t
  val mkFix : (quoted_int array * quoted_int) * (quoted_name array * t array * t array) -> t
  val mkUnknown : Constr.t -> t

  val mkMutualInductive : quoted_kernel_name -> quoted_int (* params *) ->
                          (quoted_ident * (quoted_ident * t * quoted_int) list) list ->
                          quoted_decl


  val mkConstant : quoted_kernel_name -> quoted_univ_instance -> t -> quoted_decl
  val mkAxiom : quoted_kernel_name -> t -> quoted_decl

  val mkExt : quoted_decl -> quoted_program -> quoted_program
  val mkIn : t -> quoted_program 
end

(** The reifier to Coq values *)                   
module TemplateCoqQuoter =
struct 
  type t = Term.constr

  type quoted_ident = Term.constr
  type quoted_int = Term.constr
  type quoted_bool = Term.constr
  type quoted_name = Term.constr
  type quoted_sort = Term.constr
  type quoted_cast_kind = Term.constr
  type quoted_kernel_name = Term.constr
  type quoted_recdecl = Term.constr
  type quoted_inductive = Term.constr
  type quoted_univ_instance = Term.constr
  type quoted_decl = Term.constr
  type quoted_mind_params = Term.constr
  type quoted_program = Term.constr
  type quoted_ind_entry =
    quoted_ident * t * quoted_bool * quoted_ident list * t list

  type quoted_mind_entry = Term.constr
  type quoted_mind_finiteness = Term.constr
  type quoted_definition_entry = t * t option
  type quoted_entry = Term.constr

  let resolve_symbol (path : string list) (tm : string) : Term.constr =
    gen_constant_in_modules contrib_name [path] tm

  let pkg_bignums = ["Coq";"Numbers";"BinNums"]
  let pkg_datatypes = ["Coq";"Init";"Datatypes"]
  let pkg_reify = ["Template";"Ast"]
  let pkg_string = ["Coq";"Strings";"String"]

  let r_reify = resolve_symbol pkg_reify

  let tstring = resolve_symbol pkg_string "string"
  let tString = resolve_symbol pkg_string "String"
  let tEmptyString = resolve_symbol pkg_string "EmptyString"
  let tO = resolve_symbol pkg_datatypes "O"
  let tS = resolve_symbol pkg_datatypes "S"
  let tnat = resolve_symbol pkg_datatypes "nat"
  let ttrue = resolve_symbol pkg_datatypes "true"
  let cSome = resolve_symbol pkg_datatypes "Some"
  let cNone = resolve_symbol pkg_datatypes "None"
  let tfalse = resolve_symbol pkg_datatypes "false"
  let unit_tt = resolve_symbol pkg_datatypes "tt"
  let tAscii = resolve_symbol ["Coq";"Strings";"Ascii"] "Ascii"
  let c_nil = resolve_symbol pkg_datatypes "nil"
  let c_cons = resolve_symbol pkg_datatypes "cons"
  let prod_type = resolve_symbol pkg_datatypes "prod"
  let sum_type = resolve_symbol pkg_datatypes "sum"
  let option_type = resolve_symbol pkg_datatypes "option"
  let bool_type = resolve_symbol pkg_datatypes "bool"
  let cInl = resolve_symbol pkg_datatypes "inl"
  let cInr = resolve_symbol pkg_datatypes "inr"
  let prod a b =
    Term.mkApp (prod_type, [| a ; b |])
  let c_pair = resolve_symbol pkg_datatypes "pair"
  let pair a b f s =
    Term.mkApp (c_pair, [| a ; b ; f ; s |])

    (* reify the constructors in Template.Ast.v, which are the building blocks of reified terms *)
  let nAnon = r_reify "nAnon"
  let nNamed = r_reify "nNamed"
  let kVmCast = r_reify "VmCast"
  let kNative = r_reify "NativeCast"
  let kCast = r_reify "Cast"
  let kRevertCast = r_reify "RevertCast"
  let sProp = r_reify "sProp"
  let sSet = r_reify "sSet"
  let sType = r_reify "sType"
  let tident = r_reify "ident"
  let tIndTy = r_reify "inductive"
  let tmkInd = r_reify "mkInd"
  let (tTerm,tRel,tVar,tMeta,tEvar,tSort,tCast,tProd,
       tLambda,tLetIn,tApp,tCase,tFix,tConstructor,tConst,tInd,tUnknown) =
    (r_reify "term", r_reify "tRel", r_reify "tVar", r_reify "tMeta", r_reify "tEvar",
     r_reify "tSort", r_reify "tCast", r_reify "tProd", r_reify "tLambda",
     r_reify "tLetIn", r_reify "tApp", r_reify "tCase", r_reify "tFix",
     r_reify "tConstruct", r_reify "tConst", r_reify "tInd", r_reify "tUnknown")

  let tlevel = r_reify "level"
  let tLevel = r_reify "Level"
  let tLevelVar = r_reify "LevelVar"
      
  let (tdef,tmkdef) = (r_reify "def", r_reify "mkdef")
  let (tLocalDef,tLocalAssum,tlocal_entry) = (r_reify "LocalDef", r_reify "LocalAssum", r_reify "local_entry")

  let (cFinite,cCoFinite,cBiFinite) = (r_reify "Finite", r_reify "CoFinite", r_reify "BiFinite")
  let (pConstr,pType,pAxiom,pIn) =
    (r_reify "PConstr", r_reify "PType", r_reify "PAxiom", r_reify "PIn")
  let tinductive_body = r_reify "inductive_body"
  let tmkinductive_body = r_reify "mkinductive_body"

  let tMutual_inductive_entry = r_reify "mutual_inductive_entry"
  let tOne_inductive_entry = r_reify "one_inductive_entry"
  let tBuild_mutual_inductive_entry = r_reify "Build_mutual_inductive_entry"
  let tBuild_one_inductive_entry = r_reify "Build_one_inductive_entry"
  let tConstant_entry = r_reify "constant_entry"
  let tParameter_entry = r_reify "parameter_entry"
  let tDefinition_entry = r_reify "definition_entry"
  let cParameterEntry = r_reify "ParameterEntry"
  let cDefinitionEntry = r_reify "DefinitionEntry"
  let cParameter_entry = r_reify "Build_parameter_entry"
  let cDefinition_entry = r_reify "Build_definition_entry"

  let (tmReturn,tmBind,tmQuote,tmQuoteTermRec,tmReduce,tmMkDefinition,tmMkInductive, tmPrint, tmQuoteTerm) =
    (r_reify "tmReturn", r_reify "tmBind", r_reify "tmQuote", r_reify "tmQuoteTermRec", r_reify "tmReduce",
       r_reify "tmMkDefinition", r_reify "tmMkInductive", r_reify "tmPrint", r_reify "tmQuoteTerm")

  let to_positive =
    let xH = resolve_symbol pkg_bignums "xH" in
    let xO = resolve_symbol pkg_bignums "xO" in
    let xI = resolve_symbol pkg_bignums "xI" in
    let rec to_positive n =
      if n = 1 then
	xH
      else
	if n mod 2 = 0 then
	  Term.mkApp (xO, [| to_positive (n / 2) |])
	else
  	  Term.mkApp (xI, [| to_positive (n / 2) |])
    in
    fun n ->
      if n <= 0
      then raise (Invalid_argument ("to_positive: " ^ string_of_int n))
      else to_positive n

  let to_coq_list typ =
    let the_nil = Term.mkApp (c_nil, [| typ |]) in
    let rec to_list (ls : Term.constr list) : Term.constr =
      match ls with
	[] -> the_nil
      | l :: ls ->
	Term.mkApp (c_cons, [| typ ; l ; to_list ls |])
    in to_list

  let int_to_nat =
    let cache = Hashtbl.create 10 in
    let rec recurse i =
      try Hashtbl.find cache i
      with
	Not_found ->
	  if i = 0 then
	    let result = tO in
	    let _ = Hashtbl.add cache i result in
	    result
	  else
	    let result = Term.mkApp (tS, [| recurse (i - 1) |]) in
	    let _ = Hashtbl.add cache i result in
	    result
    in
    fun i ->
      assert (i >= 0) ;
      recurse i

  let quote_bool b =
    if b then ttrue else tfalse

  let quote_char i =
    Term.mkApp (tAscii, Array.of_list (List.map (fun m -> quote_bool ((i land m) = m))
					 (List.rev [128;64;32;16;8;4;2;1])))

  let chars = Array.init 255 quote_char

  let quote_char c = chars.(int_of_char c)

  let string_hash = Hashtbl.create 420

  let to_string s =
    let len = String.length s in
    let rec go from acc =
      if from < 0 then acc
      else
        let term = Term.mkApp (tString, [| quote_char (String.get s from) ; acc |]) in
        go (from - 1) term
    in
    go (len - 1) tEmptyString
                      
  let quote_string s =
    try Hashtbl.find string_hash s
    with Not_found ->
      let term = to_string s in
      Hashtbl.add string_hash s term; term

  let quote_ident i =
    let s = Names.string_of_id i in
    quote_string s

  let quote_name n =
    match n with
      Names.Name id -> Term.mkApp (nNamed, [| quote_ident id |])
    | Names.Anonymous -> nAnon

  let quote_cast_kind k =
    match k with
      Term.VMcast -> kVmCast
    | Term.DEFAULTcast -> kCast
    | Term.REVERTcast -> kRevertCast
    | Term.NATIVEcast -> kNative

  let string_of_level s =
    to_string (Univ.Level.to_string s)

  let quote_level s =
    match Univ.Level.var_index s
    with Some x -> Term.mkApp (tLevelVar, [| int_to_nat x |])
       | None -> Term.mkApp (tLevel, [| string_of_level s|])

  let quote_universe s =
    match Univ.Universe.level s with
      Some x -> string_of_level x
    | None -> to_string ""

  let quote_univ_instance pu =
    to_coq_list tlevel (Array.to_list (Array.map quote_level (Univ.Instance.to_array pu)))

  let quote_sort s =
    match s with
      Term.Prop _ ->
	if s = Term.prop_sort then sProp
	else
	  let _ = assert (s = Term.set_sort) in
	  sSet
    | Term.Type u -> Term.mkApp (sType, [| quote_universe u |])

  let quote_inductive env (t : Names.inductive) =
    let (m,i) = t in
    Term.mkApp (tmkInd, [| quote_string (Names.string_of_kn (Names.canonical_mind m))
                	 ; int_to_nat i |])

  let mk_ctor_list =
    let ctor_list =
      let ctor_info_typ = prod (prod tident tTerm) tnat in
      to_coq_list ctor_info_typ
    in
    fun ls ->
    let ctors = List.map (fun (a,b,c) -> pair (prod tident tTerm) tnat
					 (pair tident tTerm a b) c) ls in
      Term.mkApp (tmkinductive_body, [| ctor_list ctors |])

  let rec pair_with_number st ls =
    match ls with
      [] -> []
    | l :: ls -> (st,l) :: pair_with_number (st + 1) ls

  let quote_inductive (kn, i) =
    Term.mkApp (tmkInd, [| kn; i |])

  let mkAnon = nAnon
  let mkName id = Term.mkApp (nNamed, [| id |])
  let quote_int = int_to_nat
  let quote_kn kn = quote_string (Names.string_of_kn kn)
  let mkRel i = Term.mkApp (tRel, [| i |])
  let mkVar id = Term.mkApp (tVar, [| id |])
  let mkSort s = Term.mkApp (tSort, [| s |])
  let mkCast c k t = Term.mkApp (tCast, [| c ; k ; t |])
  let mkUnknown trm = (Term.mkApp (tUnknown, [| quote_string (Format.asprintf "%a" pp_constr trm) |]))
  let mkConst kn u = Term.mkApp (tConst, [| kn ; u |])
  let mkProd na t b =
    Term.mkApp (tProd, [| na ; t ; b |])
  let mkLambda na t b =
    Term.mkApp (tLambda, [| na ; t ; b |])
  let mkApp f xs =
    Term.mkApp (tApp, [| f ; to_coq_list tTerm (Array.to_list xs) |])

  let mkLetIn na t t' b =
    Term.mkApp (tLetIn, [| na ; t ; t' ; b |])

  let mkFix ((a,b),(ns,ts,ds)) =
    let rec seq f t =
      if f < t then
	f :: seq (f + 1) t
      else
	[]
    in
    let mk_fun xs i =
      Term.mkApp (tmkdef, [| tTerm ; Array.get ns i ;
                             Array.get ts i ; Array.get ds i ; Array.get a i |]) :: xs
    in
    let defs = List.fold_left mk_fun [] (seq 0 (Array.length a)) in
    let block = to_coq_list (Term.mkApp (tdef, [| tTerm |])) (List.rev defs) in
    Term.mkApp (tFix, [| block ; b |])

  let mkConstruct (ind, i) u =
    Term.mkApp (tConstructor, [| ind ; i ; u |])

  let mkInd i u = Term.mkApp (tInd, [| i ; u |])

  let mkCase (ind, npar) nargs p c brs =
    let info = pair tIndTy tnat ind npar in
    let branches = List.map2 (fun br nargs ->  pair tnat tTerm nargs br) brs nargs in
    let tl = prod tnat tTerm in
    Term.mkApp (tCase, [| info ; p ; c ; to_coq_list tl branches |])

  let mkMutualInductive kn p ls =
    let result = to_coq_list (prod tident tinductive_body)
         (List.map (fun (a,b) ->
                                let b = mk_ctor_list b in
	                        pair tident tinductive_body a b) (List.rev ls)) in
    Term.mkApp (pType, [| kn; p; result |])

  let mkConstant kn u c =
    Term.mkApp (pConstr, [| kn; u ; c |])

  let mkAxiom kn t =
    Term.mkApp (pAxiom, [| kn; t |])

  let mkExt x acc = Term.mkApp (x, [| acc |])
  let mkIn t = Term.mkApp (pIn, [| t |])

  let quote_mind_finiteness (f: Decl_kinds.recursivity_kind) =
    match f with
    | Decl_kinds.Finite -> cFinite
    | Decl_kinds.CoFinite -> cCoFinite
    | Decl_kinds.BiFinite -> cBiFinite

  let make_one_inductive_entry (iname, arity, templatePoly, consnames, constypes) =
    let consnames = to_coq_list tident consnames in
    let constypes = to_coq_list tTerm constypes in
    Term.mkApp (tBuild_one_inductive_entry, [| iname; arity; templatePoly; consnames; constypes |])

  let quote_mind_params l =
    let pair i l = pair tident tlocal_entry i l in
    let map (id, ob) =
      match ob with
      | Left b -> pair id (Term.mkApp (tLocalDef,[|b|]))
      | Right t -> pair id (Term.mkApp (tLocalAssum,[|t|]))
    in
    let the_prod = Term.mkApp (prod_type,[|tident; tlocal_entry|]) in
    to_coq_list the_prod (List.map map l)

  let quote_mutual_inductive_entry (mf, mp, is, mpol) =
    let is = to_coq_list tOne_inductive_entry (List.map make_one_inductive_entry is) in
    let mpr = Term.mkApp (cNone, [|bool_type|]) in
    let mr = Term.mkApp (cNone, [|Term.mkApp (option_type, [|tident|])|])  in
    Term.mkApp (tBuild_mutual_inductive_entry, [| mr; mf; mp; is; mpol; mpr |])


  let quote_entry decl =
    let open Declarations in
    let opType = Term.mkApp(sum_type, [|tConstant_entry;tMutual_inductive_entry|]) in
    let mkSome c t = Term.mkApp (cSome, [|opType; Term.mkApp (c, [|tConstant_entry;tMutual_inductive_entry; t|] )|]) in
    let mkSomeDef = mkSome cInl in
    let mkSomeInd  = mkSome cInr in
    let mkParameterEntry ty =
      mkSomeDef (Term.mkApp (cParameterEntry, [| Term.mkApp (cParameter_entry, [|ty|]) |]))
    in
    let mkDefinitionEntry ty body =
      let b = Term.mkApp (cDefinitionEntry, [| Term.mkApp (cDefinition_entry, [|ty;body|]) |]) in
      mkSomeDef b
    in
    match decl with
    | Some (Left (ty, body)) ->
       (match body with
        | None -> mkParameterEntry ty
        | Some b -> mkDefinitionEntry ty b)
    | Some (Right mind) ->
       mkSomeInd mind
    | None -> Constr.mkApp (cNone, [| opType |])

end
                   
module Reify(Q : Quoter) =
struct

  let push_rel decl (in_prop, env) = (in_prop, Environ.push_rel decl env)
  let push_rel_context ctx (in_prop, env) = (in_prop, Environ.push_rel_context ctx env)

  let castSetProp (sf:Term.sorts) t =
    let sf = Term.family_of_sort sf in
    let k = Q.quote_cast_kind Constr.DEFAULTcast in
    if sf == Term.InProp
    then Q.mkCast t k (Q.mkSort (Q.quote_sort Sorts.prop))
    else if sf == Term.InSet
    then Q.mkCast t k (Q.mkSort (Q.quote_sort Sorts.set))
    else t

  let noteTypeAsCast t typ =
    Q.mkCast t (Q.quote_cast_kind Constr.DEFAULTcast) typ

  let getSort env (t:Term.constr) =
    Retyping.get_sort_of env Evd.empty (EConstr.of_constr t)

  let getType env (t:Term.constr) : Term.constr =
    EConstr.to_constr Evd.empty (Retyping.get_type_of env Evd.empty (EConstr.of_constr t))

  (* given a term of shape \x1 x2 ..., T, it puts a cast around T if T is a Set or a Prop,
     lambdas like this arise in the case-return type in matches, i.e. the part between return and with in
     match _  as   _ in  _ return __ with *)
  let rec putReturnTypeInfo (env : Environ.env) (t: Term.constr) : Term.constr =
    match Term.kind_of_term t with
    | Term.Lambda (n,t,b) ->
       Term.mkLambda (n,t,putReturnTypeInfo (Environ.push_rel (toDecl (n, None, t)) env) b)
    | _ ->
       let sf =  (getSort env t)  in
       Term.mkCast (t,Term.DEFAULTcast,Term.mkSort sf)

  open Declarations
  let abstract_inductive_instance iu =
    match iu with
    | Monomorphic_ind ctx -> Univ.Instance.empty
    | Polymorphic_ind ctx ->
       let ctx = Univ.instantiate_univ_context ctx in
       Univ.UContext.instance ctx
    | Cumulative_ind cumi ->
       let cumi = Univ.instantiate_cumulativity_info cumi in
       let ctx = Univ.CumulativityInfo.univ_context cumi in
       Univ.UContext.instance ctx
  let constant_instance = function
    | Monomorphic_const _ -> Univ.Instance.empty
    | Polymorphic_const ctx ->
       let ctx = Univ.instantiate_univ_context ctx in
       Univ.UContext.instance ctx

  let quote_term_remember
      (add_constant : Names.kernel_name -> 'a -> 'a)
      (add_inductive : Names.inductive -> 'a -> 'a) =
    let rec quote_term (acc : 'a) env trm =
      let aux acc env trm =
      match Term.kind_of_term trm with
	Term.Rel i -> (Q.mkRel (Q.quote_int (i - 1)), acc)
      | Term.Var v -> (Q.mkVar (Q.quote_ident v), acc)
      | Term.Sort s -> (Q.mkSort (Q.quote_sort s), acc)
      | Term.Cast (c,k,t) ->
	let (c',acc) = quote_term acc env c in
	let (t',acc) = quote_term acc env t in
        let k' = Q.quote_cast_kind k in
        (Q.mkCast c' k' t', acc)

      | Term.Prod (n,t,b) ->
	let (t',acc) = quote_term acc env t in
        let sf = getSort (snd env)  t in
        let env = push_rel (toDecl (n, None, t)) env in
        let sfb = getSort (snd env) b in
	let (b',acc) = quote_term acc env b in
        (Q.mkProd (Q.quote_name n) (castSetProp sf t') (castSetProp sfb b'), acc)

      | Term.Lambda (n,t,b) ->
	let (t',acc) = quote_term acc env t in
        let sf = getSort (snd env) t  in
	let (b',acc) = quote_term acc (push_rel (toDecl (n, None, t)) env) b in
	(Q.mkLambda (Q.quote_name n) (castSetProp sf t') b', acc)

      | Term.LetIn (n,e,t,b) ->
	let (e',acc) = quote_term acc env e in
	let (t',acc) = quote_term acc env t in
	let (b',acc) = quote_term acc (push_rel (toDecl (n, Some e, t)) env) b in
	(Q.mkLetIn (Q.quote_name n) e' t' b', acc)

      | Term.App (f,xs) ->
	let (f',acc) = quote_term acc env f in
	let (acc,xs') =
	  CArray.fold_map (fun acc x ->
	    let (x,acc) = quote_term acc env x in acc,x)
	    acc xs in
	(Q.mkApp f' xs', acc)

      | Term.Const (c,pu) ->
         let kn = Names.Constant.canonical c in
         let pu' = Q.quote_univ_instance pu in
	 (Q.mkConst (Q.quote_kn kn) pu', add_constant kn acc)

      | Term.Construct (((ind,i),c),pu) ->
         (Q.mkConstruct (Q.quote_inductive (Q.quote_kn (Names.MutInd.canonical ind), Q.quote_int i),
                         Q.quote_int (c - 1))
            (Q.quote_univ_instance pu), add_inductive (ind,i) acc)

      | Term.Ind ((ind,i),pu) ->
         (Q.mkInd (Q.quote_inductive (Q.quote_kn (Names.MutInd.canonical ind), Q.quote_int i))
            (Q.quote_univ_instance pu), add_inductive (ind,i) acc)

      | Term.Case (ci,typeInfo,discriminant,e) ->
         let ind = Q.quote_inductive (Q.quote_kn (Names.MutInd.canonical (fst ci.Term.ci_ind)),
                                      Q.quote_int (snd ci.Term.ci_ind)) in
         let npar = Q.quote_int ci.Term.ci_npar in
         let discriminantType = getType (snd env) discriminant in
         let typeInfo = putReturnTypeInfo (snd env) typeInfo in
	 let (qtypeInfo,acc) = quote_term acc env typeInfo in
	 let (discriminant,acc) = quote_term acc env discriminant in
         let (discriminantType,acc) = (quote_term acc env discriminantType) in
         let discriminant = noteTypeAsCast discriminant discriminantType in
	 let (branches,nargs,acc) =
           CArray.fold_left2 (fun (xs,nargs,acc) x narg ->
               let (x,acc) = quote_term acc env x in
               let narg = Q.quote_int narg in
               (x :: xs, narg :: nargs, acc))
             ([],[],acc) e ci.Term.ci_cstr_nargs in
         (Q.mkCase (ind, npar) (List.rev nargs) qtypeInfo discriminant (List.rev branches), acc)

      | Term.Fix fp -> quote_fixpoint acc env fp

      | _ -> (Q.mkUnknown trm, acc)

      in
      let in_prop, env' = env in 
      if is_cast_prop () && not in_prop then
        let ty =
          let trm = EConstr.of_constr trm in
          try Retyping.get_type_of env' Evd.empty trm
          with e ->
            Feedback.msg_debug (str"Anomaly trying to get the type of: " ++
                                  Termops.print_constr_env (snd env) Evd.empty trm);
            raise e
        in
        let sf =
          try Retyping.get_sort_family_of env' Evd.empty ty
          with e ->
            Feedback.msg_debug (str"Anomaly trying to get the sort of: " ++
                                  Termops.print_constr_env (snd env) Evd.empty ty);
            raise e
        in
        if sf == Term.InProp then
          aux acc (true, env')
              (Term.mkCast (trm, Term.DEFAULTcast,
                            Term.mkCast (EConstr.to_constr Evd.empty ty, Term.DEFAULTcast, Term.mkProp))) 
        else aux acc env trm
      else aux acc env trm
    and quote_fixpoint (acc : 'a) env t =
      let ((a,b),(ns,ts,ds)) = t in
      let ctxt = CArray.map2_i (fun i na t -> (Context.Rel.Declaration.LocalAssum (na, Vars.lift i t))) ns ts in
      let envfix = push_rel_context (CArray.rev_to_list ctxt) env in
      let ns' = Array.map Q.quote_name ns in
      let a' = Array.map Q.quote_int a in
      let b' = Q.quote_int b in
      let acc, ts' =
        CArray.fold_map (fun acc t -> let x,acc = quote_term acc env t in acc, x) acc ts in
      let acc, ds' =
        CArray.fold_map (fun acc t -> let x,y = quote_term acc envfix t in y, x) acc ds in
      (Q.mkFix ((a',b'),(ns',ts',ds')), acc)
    and quote_minductive_type (acc : 'a) env (t : Names.mutual_inductive) =
      let mib = Environ.lookup_mind t (snd env) in
      let inst = abstract_inductive_instance mib.Declarations.mind_universes in
      let indtys =
        Array.to_list Declarations.(Array.map (fun oib ->
           let ty = Inductive.type_of_inductive (snd env) ((mib,oib),inst) in
           (Context.Rel.Declaration.LocalAssum (Names.Name oib.mind_typename, ty))) mib.mind_packets)
      in
      let envind = push_rel_context (List.rev indtys) env in
      let ref_name = Q.quote_kn (Names.canonical_mind t) in
      let (ls,acc) =
	List.fold_left (fun (ls,acc) oib ->
	  let named_ctors =
	    CList.combine3
	      Declarations.(Array.to_list oib.mind_consnames)
	      Declarations.(Array.to_list oib.mind_user_lc)
	      Declarations.(Array.to_list oib.mind_consnrealargs)
	  in
	  let (reified_ctors,acc) =
	    List.fold_left (fun (ls,acc) (nm,ty,ar) ->
	      debug (fun () -> Pp.(str "XXXX" ++ spc () ++
                            bool !opt_hnf_ctor_types)) ;
	      let ty = if !opt_hnf_ctor_types then hnf_type (snd envind) ty else ty in
	      let (ty,acc) = quote_term acc envind ty in
	      ((Q.quote_ident nm, ty, Q.quote_int ar) :: ls, acc))
	      ([],acc) named_ctors
	  in
	  Declarations.((Q.quote_ident oib.mind_typename, (List.rev reified_ctors)) :: ls, acc))
	  ([],acc) Declarations.((Array.to_list mib.mind_packets))
      in
      let params = Q.quote_int mib.Declarations.mind_nparams in
      Q.mkMutualInductive ref_name params (List.rev ls), acc
    in ((fun acc env -> quote_term acc (false, env)),
        (fun acc env -> quote_minductive_type acc (false, env)))

  let quote_term env trm =
    let (fn,_) = quote_term_remember (fun _ () -> ()) (fun _ () -> ()) in
    fst (fn () env trm)

  type defType =
    Ind of Names.inductive
  | Const of Names.kernel_name

  let quote_term_rec env trm =
    let visited_terms = ref Names.KNset.empty in
    let visited_types = ref Mindset.empty in
    let constants = ref [] in
    let add quote_term quote_type trm acc =
      match trm with
      | Ind (mi,idx) ->
	let t = mi in
	if Mindset.mem t !visited_types then ()
	else
	  begin
	    let (result,acc) =
              try quote_type acc env mi
              with e ->
                Feedback.msg_debug (str"Exception raised while checking " ++ Names.pr_mind mi);
                raise e
            in
	    visited_types := Mindset.add t !visited_types ;
	    constants := result :: !constants
	  end
      | Const kn ->
	if Names.KNset.mem kn !visited_terms then ()
	else
	  begin
	    visited_terms := Names.KNset.add kn !visited_terms ;
            let c = Names.Constant.make kn kn in
	    let cd = Environ.lookup_constant c env in
	    let do_body body pu =
	      let (result,acc) =
		try quote_term acc (Global.env ()) body
                with e ->
                  Feedback.msg_debug (str"Exception raised while checking body of " ++ Names.pr_kn kn);
                  raise e
	      in
	      constants := Q.mkConstant (Q.quote_kn kn) (Q.quote_univ_instance pu) result :: !constants
	    in
	    Declarations.( 
	      match cd.const_body, cd.const_universes with
		Undef _, _ ->
		begin
		  let (ty,acc) =
		    match cd.const_type with
		    | RegularArity ty ->
                       (try quote_term acc (Global.env ()) ty
                        with e ->
                           Feedback.msg_debug (str"Exception raised while checking type of " ++ Names.pr_kn kn);
                           raise e)
		    | TemplateArity _ -> assert false
		  in
		  constants := Q.mkAxiom (Q.quote_kn kn) ty :: !constants
		end
	      | Def cs, pu ->
		do_body (Mod_subst.force_constr cs) (constant_instance pu)
	      | OpaqueDef lc, pu ->
		do_body (Opaqueproof.force_proof (Global.opaque_tables ()) lc) (constant_instance pu))
	  end
    in
    let (quote_rem,quote_typ) =
      let a = ref (fun _ _ _ -> assert false) in
      let b = ref (fun _ _ _ -> assert false) in
      let (x,y) =
	quote_term_remember (fun x () -> add !a !b (Const x) ())
	                    (fun y () -> add !a !b (Ind y) ())
      in
      a := x ;
      b := y ;
      (x,y)
    in
    let (x,acc) = quote_rem () env trm
    in List.fold_left (fun acc x -> Q.mkExt x acc)
                      (Q.mkIn x) !constants

  let quote_one_ind envA envC (mi:Entries.one_inductive_entry) =
    let open Declarations in
    let open Entries in
    let iname = Q.quote_ident mi.mind_entry_typename  in
    let arity = quote_term envA mi.mind_entry_arity in
    let templatePoly = Q.quote_bool mi.mind_entry_template in
    let consnames = List.map Q.quote_ident (mi.mind_entry_consnames) in
    let constypes = List.map (quote_term envC) (mi.mind_entry_lc) in
    (iname, arity, templatePoly, consnames, constypes)

  let process_local_entry
        (f: 'a -> Term.constr option (* body *) -> Term.constr (* type *) -> Names.Id.t -> Environ.env -> 'a)
        ((env,a):(Environ.env*'a))
        ((n,le):(Names.Id.t * Entries.local_entry))
      :  (Environ.env * 'a) =
    match le with
    | Entries.LocalAssumEntry t -> (Environ.push_rel (toDecl (Names.Name n,None,t)) env, f a None t n env)
    | Entries.LocalDefEntry b ->
       let typ = getType env b in
       (Environ.push_rel (toDecl (Names.Name n, Some b, typ)) env, f a (Some b) typ n env)


  let quote_mind_params env (params:(Names.Id.t * Entries.local_entry) list) =
    let f lr ob t n env =
      match ob with
      | Some b -> (Q.quote_ident n, Left (quote_term env b))::lr
      | None ->
         let sf = getSort env t in
         let t' = castSetProp sf (quote_term env t) in
         (Q.quote_ident n, Right t')::lr in
    let (env, params) = List.fold_left (process_local_entry f) (env,[]) (List.rev params) in
    (env, Q.quote_mind_params (List.rev params))

  let mind_params_as_types ((env,t):Environ.env*Term.constr) (params:(Names.Id.t * Entries.local_entry) list) : 
        Environ.env*Term.constr =
    List.fold_left (process_local_entry (fun tr ob typ n env -> Term.mkProd_or_LetIn (toDecl (Names.Name n,ob,typ)) tr)) (env,t) 
      (List.rev params)

  let quote_mut_ind env (mi:Declarations.mutual_inductive_body) =
   let t= Discharge.process_inductive ([],Univ.AUContext.empty) (Names.Cmap.empty,Names.Mindmap.empty) mi in
    let open Declarations in
    let open Entries in
    let mf = Q.quote_mind_finiteness t.mind_entry_finite in
    let mp = (snd (quote_mind_params env (t.mind_entry_params))) in
    (* before quoting the types of constructors, we need to enrich the environment with the inductives *)
    let one_arities =
      List.map 
        (fun x -> (x.mind_entry_typename,
                   snd (mind_params_as_types (env,x.mind_entry_arity) (t.mind_entry_params))))
        t.mind_entry_inds in
    (* env for quoting constructors of inductives. First push inductices, then params *)
    let envC = List.fold_left (fun env p -> Environ.push_rel (toDecl (Names.Name (fst p), None, snd p)) env) env (one_arities) in
    let (envC,_) = List.fold_left (process_local_entry (fun _ _ _ _ _ -> ())) (envC,()) (List.rev (t.mind_entry_params)) in
    (* env for quoting arities of inductives -- just push the params *)
    let (envA,_) = List.fold_left (process_local_entry (fun _ _ _ _ _ -> ())) (env,()) (List.rev (t.mind_entry_params)) in
    let is = List.map (quote_one_ind envA envC) t.mind_entry_inds in
    let mpol = Q.quote_bool false in
    Q.quote_mutual_inductive_entry (mf, mp, is, mpol)

  let kn_of_canonical_string s =
    let ss = List.rev (Str.split (Str.regexp (Str.quote ".")) s) in
    match ss with
      nm :: rst ->
	let to_mp ls = Names.MPfile (Names.make_dirpath (List.map Names.id_of_string ls)) in
	let mp = to_mp rst in
	Names.make_kn mp Names.empty_dirpath (Names.mk_label nm)
    | _ -> assert false

  let quote_entry bypass env evm (name:string) =
    let (dp, nm) = split_name name in
    let entry =
      match Nametab.locate (Libnames.make_qualid dp nm) with
      | Globnames.ConstRef c ->
         let cd = Environ.lookup_constant c env in
         let ty =
           match cd.const_type with
           | RegularArity ty -> quote_term env ty
           | TemplateArity _ ->
              CErrors.user_err (Pp.str "Cannot reify deprecated template-polymorphic constant types")
         in
         let body = match cd.const_body with
           | Undef _ -> None
           | Def cs -> Some (quote_term env (Mod_subst.force_constr cs))
           | OpaqueDef cs ->
              if bypass
              then Some (quote_term env (Opaqueproof.force_proof (Global.opaque_tables ()) cs))
              else None
         in Some (Left (ty, body))

      | Globnames.IndRef ni ->
         let c = Environ.lookup_mind (fst ni) env in (* FIX: For efficienctly, we should also export (snd ni)*)
         let miq = quote_mut_ind env c in
         Some (Right miq)
      | Globnames.ConstructRef _ -> None (* FIX?: return the enclusing mutual inductive *)
      | Globnames.VarRef _ -> None
    in Q.quote_entry entry
end

module TermReify = Reify(TemplateCoqQuoter)

module Denote =
struct

  open TemplateCoqQuoter
  
  let rec app_full trm acc =
    match Term.kind_of_term trm with
      Term.App (f, xs) -> app_full f (Array.to_list xs @ acc)
    | _ -> (trm, acc)

  let rec nat_to_int trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h tO then
      0
    else if Term.eq_constr h tS then
      match args with
	n :: _ -> 1 + nat_to_int n
      | _ -> not_supported_verb trm "nat_to_int nil"
    else
      not_supported_verb trm "nat_to_int"

  let from_bool trm =
    if Term.eq_constr trm ttrue then
      true
    else if Term.eq_constr trm tfalse then
      false
    else not_supported_verb trm "from_bool"

  let unquote_char trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h tAscii then
      match args with
	a :: b :: c :: d :: e :: f :: g :: h :: _ ->
	  let bits = List.rev [a;b;c;d;e;f;g;h] in
	  let v = List.fold_left (fun a n -> (a lsl 1) lor if from_bool n then 1 else 0) 0 bits in
	  char_of_int v
      | _ -> assert false
    else
      not_supported trm
(*
let reduce_all env (evm,def) =
  	let (evm2,red) = Tacinterp.interp_redexp env evm (Genredexpr.Cbv Redops.all_flags) in
	  let red = fst (Redexpr.reduction_of_red_expr env red) in
	  red env evm2 def
*)

  let reduce_hnf env (evm,(def:Term.constr)) =
    (evm,EConstr.to_constr Evd.empty (Tacred.hnf_constr env evm (EConstr.of_constr def))) 

  let reduce_all env (evm,(def:Term.constr))  =
     (evm,EConstr.to_constr Evd.empty (Redexpr.cbv_vm env evm (EConstr.of_constr def)))

  let unquote_string trm =
    let rec go n trm =
      let (h,args) = app_full trm [] in
      if Term.eq_constr h tEmptyString then
        Bytes.create n
      else if Term.eq_constr h tString then
	match args with
	  c :: s :: _ ->
	    let res = go (n + 1) s in
	    let _ = Bytes.set res n (unquote_char c) in
	    res
	| _ -> bad_term_verb trm "unquote_string"
      else
	not_supported_verb trm "unquote_string"
    in
    Bytes.to_string (go 0 trm)

  let unquote_ident trm =
    Names.id_of_string (unquote_string trm)

  let unquote_cast_kind trm =
    if Term.eq_constr trm kVmCast then
      Term.VMcast
    else if Term.eq_constr trm kCast then
      Term.DEFAULTcast
    else if Term.eq_constr trm kRevertCast then
      Term.REVERTcast
    else if Term.eq_constr trm kNative then
      Term.VMcast
    else
      bad_term trm


  let unquote_name trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h nAnon then
      Names.Anonymous
    else if Term.eq_constr h nNamed then
      match args with
	n :: _ -> Names.Name (unquote_ident n)
      | _ -> raise (Failure "ill-typed, expected name")
    else
      raise (Failure "non-value")


  (* This code is taken from Pretyping, because it is not exposed globally *)
  let strict_universe_declarations = ref true
  let is_strict_universe_declarations () = !strict_universe_declarations
  let get_universe evd (loc, s) =
        let names, _ = Global.global_universe_names () in
        if CString.string_contains ~where:s ~what:"." then
          match List.rev (CString.split '.' s) with
          | [] -> CErrors.anomaly (str"Invalid universe name " ++ str s ++ str".")
          | n :: dp ->
	     let num = int_of_string n in
	     let dp = Names.DirPath.make (List.map Names.Id.of_string dp) in
	     let level = Univ.Level.make dp num in
	     let evd =
	       try Evd.add_global_univ evd level
	       with UGraph.AlreadyDeclared -> evd
	     in evd, level
        else
          try
	    let level = Evd.universe_of_name evd s in
	    evd, level
          with Not_found ->
	    try
	      let id = try Names.Id.of_string s with _ -> raise Not_found in
              evd, snd (Names.Idmap.find id names)
	    with Not_found ->
	      CErrors.user_err ?loc ~hdr:"interp_universe_level_name"
		            (Pp.(str "Undeclared universe: " ++ str s))
  (* end of code from Pretyping *)
                 
  let unquote_sort trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h sType then
      match args with
        x :: _ -> let _, lvl = get_universe Evd.empty (None, unquote_string x) in
                  Term.sort_of_univ (Univ.Universe.make lvl)
      | _ -> bad_term_verb trm "no Type"
    else if Term.eq_constr h sProp then
      Term.prop_sort
    else if Term.eq_constr h sSet then
      Term.set_sort
    else
      raise (Failure "ill-typed, expected sort")



  let denote_inductive trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h tmkInd then
      match args with
	nm :: num :: _ ->
        let s = (unquote_string nm) in
        let (dp, nm) = split_name s in
        (try 
          match Nametab.locate (Libnames.make_qualid dp nm) with
          | Globnames.ConstRef c ->  raise (Failure (String.concat "this not an inductive constant. use tConst instead of tInd : " [s]))
          | Globnames.IndRef i -> (fst i, nat_to_int  num)
          | Globnames.VarRef _ -> raise (Failure (String.concat "the constant is a variable. use tVar : " [s]))
          | Globnames.ConstructRef _ -> raise (Failure (String.concat "the constant is a consructor. use tConstructor : " [s]))
        with
        Not_found ->   raise (Failure (String.concat "Constant not found : " [s])))
      | _ -> assert false
    else
      raise (Failure "non-constructor")

  let rec from_coq_list trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h c_nil then []
    else if Term.eq_constr h c_cons then
      match args with
	_ :: x :: xs :: _ -> x :: from_coq_list xs
      | _ -> bad_term trm
    else
      not_supported_verb trm "from_coq_list"




  (* let reduce_all env (evm,def) rd = *)
  (*   let (evm2,red) = Ltac_plugin.Tacinterp.interp_redexp env evm rd in *)
  (*   let red = fst (Redexpr.reduction_of_red_expr env red) in *)
  (*   let Sigma.Sigma (c, evm, _) = red.Reductionops.e_redfun env (Sigma.Unsafe.of_evar_map evm2) def in *)
  (*   Sigma.to_evar_map evm, c *)

  let from_coq_pair trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h c_pair then
      match args with
	_ :: _ :: x :: y :: [] -> (x, y)
      | _ -> bad_term trm
    else
      not_supported_verb trm "from_coq_pair"

(*
Stm.interp
Vernacentries.interp
Vernacexpr.Check
*)

  (** NOTE: Because the representation is lossy, I should probably
   ** come back through elaboration.
   ** - This would also allow writing terms with holes
   **)
  let rec denote_term trm =
    debug (fun () -> Pp.(str "denote_term" ++ spc () ++ Printer.pr_constr trm)) ;
    let (h,args) = app_full trm [] in
    if Term.eq_constr h tRel then
      match args with
	x :: _ ->
	  Term.mkRel (nat_to_int x + 1)
      | _ -> raise (Failure "ill-typed")
    else if Term.eq_constr h tVar then
      match args with
	x :: _ -> Term.mkVar (unquote_ident x)
      | _ -> raise (Failure "ill-typed")
    else if Term.eq_constr h tSort then
      match args with
	x :: _ -> Term.mkSort (unquote_sort x)
      | _ -> raise (Failure "ill-typed")
    else if Term.eq_constr h tCast then
      match args with
	t :: c :: ty :: _ ->
	  Term.mkCast (denote_term t, unquote_cast_kind c, denote_term ty)
      | _ -> raise (Failure "ill-typed")
    else if Term.eq_constr h tProd then
      match args with
	n :: t :: b :: _ ->
	  Term.mkProd (unquote_name n, denote_term t, denote_term b)
      | _ -> raise (Failure "ill-typed (product)")
    else if Term.eq_constr h tLambda then
      match args with
	n :: t :: b :: _ ->
	Term.mkLambda (unquote_name n, denote_term t, denote_term b)
      | _ -> raise (Failure "ill-typed (lambda)")
    else if Term.eq_constr h tLetIn then
      match args with
	n :: e :: t :: b :: _ ->
	  Term.mkLetIn (unquote_name n, denote_term e, denote_term t, denote_term b)
      | _ -> raise (Failure "ill-typed (let-in)")
    else if Term.eq_constr h tApp then
      match args with
	f :: xs :: _ ->
	  Term.mkApp (denote_term f,
		      Array.of_list (List.map denote_term (from_coq_list xs)))
      | _ -> raise (Failure "ill-typed (app)")
    else if Term.eq_constr h tConst then
      match args with
    	s :: [] ->
        let s = (unquote_string s) in
        let (dp, nm) = split_name s in
        (try 
          match Nametab.locate (Libnames.make_qualid dp nm) with
          | Globnames.ConstRef c ->  Term.mkConst c
          | Globnames.IndRef _ -> raise (Failure (String.concat "the constant is an inductive. use tInd : " [s]))
          | Globnames.VarRef _ -> raise (Failure (String.concat "the constant is a variable. use tVar : " [s]))
          | Globnames.ConstructRef _ -> raise (Failure (String.concat "the constant is a consructor. use tConstructor : " [s]))
        with
        Not_found ->   raise (Failure (String.concat "Constant not found : " [s])))

      | _ -> raise (Failure "ill-typed (tConst)")
    else if Term.eq_constr h tConstructor then
      match args with
	i :: idx :: _ ->
	  let i = denote_inductive i in
	  Term.mkConstruct (i, nat_to_int idx + 1)
      | _ -> raise (Failure "ill-typed (constructor)")
    else if Term.eq_constr h tInd then
      match args with
	i :: _ ->
	  let i = denote_inductive i in
	  Term.mkInd i
      | _ -> raise (Failure "ill-typed (inductive)")
    else if Term.eq_constr h tCase then
      match args with
	info :: ty :: d :: brs :: _ ->
          let i, _ = from_coq_pair info in
          let ind = denote_inductive i in
          let ci = Inductiveops.make_case_info (Global.env ()) ind Term.RegularStyle in
          let denote_branch br =
            let _, br = from_coq_pair br in
            denote_term br
          in
	  Term.mkCase (ci, denote_term ty, denote_term d,
			Array.of_list (List.map denote_branch (from_coq_list brs)))
      | _ -> raise (Failure "ill-typed (case)")
    else if Term.eq_constr h tFix then
      match args with
	    bds :: i :: _ ->
        let unquoteFbd  b : ((Term.constr * Term.constr) * (Term.constr * Term.constr)) =
          let (_,args) = app_full b [] in
          match args with
          | _(*type*)::a::b::c::d::[] -> ((a,b),(c,d))
          |_ -> raise (Failure " (mkdef must take exactly 5 arguments)")
          in
        let lbd = List.map unquoteFbd (from_coq_list bds) in
        let (p1,p2) = (List.map fst lbd, List.map snd lbd) in
        let (names,types,bodies,rargs) = (List.map fst p1, List.map snd p1, List.map fst p2, List.map snd p2) in
        let (types,bodies) = (List.map denote_term types, List.map denote_term bodies) in
        let (names,rargs) = (List.map unquote_name names, List.map nat_to_int rargs) in
        let la = Array.of_list in
        Term.mkFix ((la rargs,nat_to_int i), (la names, la types, la bodies))
      | _ -> raise (Failure "tFix takes exactly 2 arguments")
    else
      not_supported_verb trm "big_case"

(*
  let declare_definition
    (id : Names.Id.t) (loc, boxed_flag, def_obj_kind)
    (binder_list : Constrexpr.local_binder list) red_expr_opt (constr_expr : Constrexpr.constr_expr)
    constr_expr_opt decl_hook =
    Command.do_definition
    id (loc, false, def_obj_kind) None binder_list red_expr_opt constr_expr
    constr_expr_opt decl_hook

  let add_definition name result =
    declare_definition name
	    (Decl_kinds.Global, false, Decl_kinds.Definition)
	    [] None result None (Lemmas.mk_hook (fun _ _ -> ()))
*)




  let unquote_red_add_definition b env evm name def =
	  let (evm,def) = reduce_all env (evm,def) in
  	let trm = if b then denote_term def else def in
    if b then Feedback.msg_debug ((Printer.pr_constr trm)) else ();
    Declare.declare_definition 
	  ~kind:Decl_kinds.Definition name
	  (trm, (* No new universe constraints can be generated by typing the AST *)
           Univ.ContextSet.empty)
	  
  let denote_local_entry trm =
    let (h,args) = app_full trm [] in
      match args with
	    x :: [] -> 
      if Term.eq_constr h tLocalDef then Entries.LocalDefEntry (denote_term x) 
      else (if  Term.eq_constr h tLocalAssum then Entries.LocalAssumEntry (denote_term x) else bad_term trm)
      | _ -> bad_term trm

  let denote_mind_entry_finite trm =
    let (h,args) = app_full trm [] in
      match args with
	    [] -> 
      if Term.eq_constr h cFinite then Decl_kinds.Finite
      else if  Term.eq_constr h cCoFinite then Decl_kinds.CoFinite
      else if  Term.eq_constr h cBiFinite then Decl_kinds.BiFinite
      else bad_term trm
      | _ -> bad_term trm

  let unquote_map_option f trm =
    let (h,args) = app_full trm [] in
    if Term.eq_constr h cSome then 
    match args with
	  _ :: x :: _ -> Some (f x)
      | _ -> bad_term trm
    else if Term.eq_constr h cNone then 
    match args with
	  _ :: [] -> None
      | _ -> bad_term trm
    else
      not_supported_verb trm "unqote_map_option"


  let declare_inductive (env: Environ.env) (evm: Evd.evar_map) (body: Term.constr) : unit =
  let open Entries in
  let (evm,body) = reduce_all env (evm, body)  (* (Genredexpr.Cbv Redops.all_flags) *) in
  let (_,args) = app_full body [] in (* check that the first component is Build_mut_ind .. *) 
  let one_ind b1 : Entries.one_inductive_entry = 
    let (_,args) = app_full b1 [] in (* check that the first component is Build_one_ind .. *)
    match args with
    | mt::ma::mtemp::mcn::mct::[] ->
    {
    mind_entry_typename = unquote_ident mt;
    mind_entry_arity = denote_term ma;
    mind_entry_template = from_bool mtemp;
    mind_entry_consnames = List.map unquote_ident (from_coq_list mcn);
    mind_entry_lc = List.map denote_term (from_coq_list mct)
    } 
    | _ -> raise (Failure "ill-typed one_inductive_entry")
     in 
  let mut_ind mr mf mp mi mpol mpr : Entries.mutual_inductive_entry =
    {
    mind_entry_record = unquote_map_option (unquote_map_option unquote_ident) mr;
    mind_entry_finite = denote_mind_entry_finite mf; (* inductive *)
    mind_entry_params = List.map (fun p -> let (l,r) = (from_coq_pair p) in (unquote_ident l, (denote_local_entry r))) 
      (List.rev (from_coq_list mp));
    mind_entry_inds = List.map one_ind (from_coq_list mi);
    (* mind_entry_polymorphic = from_bool mpol; *)
    mind_entry_universes =
      if from_bool mpol then
        (Polymorphic_ind_entry (snd (Evd.universe_context evm)))
      else Monomorphic_ind_entry (snd (Evd.universe_context evm));
    mind_entry_private = unquote_map_option from_bool mpr (*mpr*)
    } in 
    match args with
    mr::mf::mp::mi::mpol::mpr::[] -> 
      ignore(Command.declare_mutual_inductive_with_eliminations (mut_ind mr mf mp mi mpol mpr) [] [])
    | _ -> raise (Failure "ill-typed mutual_inductive_entry")

  let declare_interpret_inductive (env: Environ.env) (evm: Evd.evar_map) (body: Constrexpr.constr_expr) : unit =
	let (body,_) = Constrintern.interp_constr env evm body in
  declare_inductive env evm body

  let rec run_template_program_rec  ((env,evm,pgm): Environ.env * Evd.evar_map * Term.constr) : Environ.env * Evd.evar_map * Term.constr =
    let (evm,pgm) = reduce_hnf env (evm, pgm) in 
    let (coConstr,args) = app_full pgm [] in
    if Term.eq_constr coConstr tmReturn then
      match args with
      | _::h::[] -> (env,evm,h)
      | _ -> raise (Failure "tmReturn must take 2 arguments. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmBind then
      match args with
      | _::_::a::f::[] ->
        let (env, evm, ar) = run_template_program_rec (env,evm,a) in
        run_template_program_rec (env,evm,(Term.mkApp (f, Array.of_list [ar])))
      | _ -> raise (Failure "tmBind must take 4 arguments. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmMkDefinition then
      match args with
      | b::name::_::body::[] -> 
        let (evm,name) = reduce_all env (evm,name) in
        let (evm,b) = reduce_all env (evm,b) in
        let _ = unquote_red_add_definition (from_bool b) env evm (unquote_ident name) body in (env, evm, unit_tt)
      | _ -> raise (Failure "tmMkDefinition must take 4 arguments. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmQuote then
      match args with
      | id::b::[] ->
          let (evm,id) = reduce_all env (evm,id) in
          let (evm,b) = reduce_all env (evm,b) in
          let qt = TermReify.quote_entry (from_bool b) env evm (unquote_string id) in
          (env, evm, qt)
      | _ -> raise (Failure "tmQuote must take 1 argument. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmQuoteTerm then
      match args with
      | _::trm::[] -> let qt = TermReify.quote_term env trm in (* user should do the reduction (using tmReduce) if they want *)
              (env, evm, qt)
      | _ -> raise (Failure "tmQuoteTerm must take 1 argument. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmQuoteTermRec then
      match args with
      | trm::[] -> let qt = TermReify.quote_term_rec env trm in
              (env, evm, qt)
      | _ -> raise (Failure "tmQuoteTermRec must take 1 argument. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmPrint then
      match args with
      | _::trm::[] -> let _ = Feedback.msg_debug ((Printer.pr_constr trm)) in (env, evm, unit_tt)
      | _ -> raise (Failure "tmPrint must take 2 arguments. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmReduce then
      match args with
      | _(*reduction strategy*)::_(*type*)::trm::[] -> 
          let (evm,trm) = reduce_all env (evm,trm) in (env, evm, trm)
      | _ -> raise (Failure "tmReduce must take 3 arguments. Please file a bug with Template-Coq.")
    else if Term.eq_constr coConstr tmMkInductive then
      match args with
      | mind::[] -> let _ = declare_inductive env evm mind in (env, evm, unit_tt)
      | _ -> raise (Failure "tmReduce must take 3 arguments. Please file a bug with Template-Coq.")
    else raise (Failure "Invalid argument or yot yet implemented. The argument must be a TemplateProgram")

  let run_template_program (env: Environ.env) (evm: Evd.evar_map) (body: Constrexpr.constr_expr) : unit =
  	let (body,_) = Constrintern.interp_constr env evm body in
    let _ = run_template_program_rec (env,evm,body) in ()
end

DECLARE PLUGIN "template_plugin"

(** Stolen from CoqPluginUtils **)
(** Calling Ltac **)
let ltac_call tac (args:Tacexpr.glob_tactic_arg list) =
  Tacexpr.TacArg(Loc.tag @@ Tacexpr.TacCall (Loc.tag (Misctypes.ArgArg(Loc.tag @@ Lazy.force tac),args)))

(* let ltac_call tac (args:Tacexpr.glob_tactic_arg list) = *)
(*   Tacexpr.TacArg(Loc.ghost,Tacexpr.TacCall(Loc.ghost, Misctypes.ArgArg(Loc.ghost, Lazy.force tac),args)) *)

(* Calling a locally bound tactic *)
(* let ltac_lcall tac args = *)
(*   Tacexpr.TacArg(Loc.ghost,Tacexpr.TacCall(Loc.ghost, Misctypes.ArgVar(Loc.ghost, Names.id_of_string tac),args)) *)
let ltac_lcall tac args =
  Tacexpr.TacArg(Loc.tag @@ Tacexpr.TacCall (Loc.tag (Misctypes.ArgVar(Loc.tag @@ Names.Id.of_string tac),args)))

(* let ltac_letin (x, e1) e2 = *)
(*   Tacexpr.TacLetIn(false,[(Loc.ghost,Names.id_of_string x),e1],e2) *)

open Names
open Tacexpr
open Tacinterp
open Misctypes

   
let ltac_apply (f : Value.t) (args: Tacinterp.Value.t list) =
  let fold arg (i, vars, lfun) =
    let id = Names.Id.of_string ("x" ^ string_of_int i) in
    let x = Reference (ArgVar (Loc.tag id)) in
    (succ i, x :: vars, Id.Map.add id arg lfun)
  in
  let (_, args, lfun) = List.fold_right fold args (0, [], Id.Map.empty) in
  let lfun = Id.Map.add (Id.of_string "F") f lfun in
  let ist = { (Tacinterp.default_ist ()) with Tacinterp.lfun = lfun; } in
  Tacinterp.eval_tactic_ist ist (ltac_lcall "F" args)

(* let ltac_apply (f:Tacexpr.glob_tactic_expr) (args:Tacexpr.glob_tactic_arg list) = *)
(*   Tacinterp.eval_tactic *)
(*     (ltac_letin ("F", Tacexpr.Tacexp f) (ltac_lcall "F" args)) *)

let to_ltac_val c = Tacinterp.Value.of_constr c

let to_ltac_val c = Tacinterp.Value.of_constr c
(** From Containers **)
let declare_definition
    (id : Names.Id.t) (loc, boxed_flag, def_obj_kind)
    (binder_list) red_expr_opt constr_expr
    constr_expr_opt decl_hook =
  Command.do_definition
  id (loc, false, def_obj_kind) None binder_list red_expr_opt constr_expr
  constr_expr_opt decl_hook

let check_inside_section () =
  if Lib.sections_are_opened () then
    (** In trunk this seems to be moved to Errors **)
    (* For Coq 8.7: CErrors.user_err ~hdr:"Quote" (Pp.str "You can not quote within a section.") *)
    CErrors.user_err ~hdr:"Quote" (Pp.str "You can not quote within a section.")
  else ()

open Stdarg
open Tacarg
open Proofview.Notations
open Pp

TACTIC EXTEND get_goal
    | [ "quote_term" constr(c) tactic(tac) ] ->
      [ (** quote the given term, pass the result to t **)
  Proofview.Goal.nf_enter begin fun gl ->
          let env = Proofview.Goal.env gl in
	  let c = TermReify.quote_term env (EConstr.to_constr (Proofview.Goal.sigma gl) c) in
	  ltac_apply tac (List.map to_ltac_val [EConstr.of_constr c])
  end ]
(*
    | [ "quote_goal" ] ->
      [ (** get the representation of the goal **)
	fun gl -> assert false ]
    | [ "get_inductive" constr(i) ] ->
      [ fun gl -> assert false ]
*)
END;;

TACTIC EXTEND denote_term
    | [ "denote_term" constr(c) tactic(tac) ] ->
      [ Proofview.Goal.nf_enter begin fun gl ->
         let (evm,env) = Lemmas.get_current_context() in
         let c = Denote.denote_term (EConstr.to_constr (Proofview.Goal.sigma gl) c) in
         let def' = Constrextern.extern_constr true env evm (EConstr.of_constr c) in
         let def = Constrintern.interp_constr env evm def' in
	 ltac_apply tac (List.map to_ltac_val [EConstr.of_constr (fst def)])
      end ]
END;;


VERNAC COMMAND EXTEND Make_vernac CLASSIFIED AS SIDEFF
    | [ "Quote" "Definition" ident(name) ":=" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
	let def = Constrintern.interp_constr env evm def in
	let trm = TermReify.quote_term env (fst def) in
	ignore(Declare.declare_definition ~kind:Decl_kinds.Definition name
                                          (trm, Univ.ContextSet.empty)) ]
END;;

VERNAC COMMAND EXTEND Make_vernac_reduce CLASSIFIED AS SIDEFF
    | [ "Quote" "Definition" ident(name) ":=" "Eval" red_expr(rd) "in" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
	let def, uctx = Constrintern.interp_constr env evm def in
        let evm = Evd.from_ctx uctx in
	let (evm2,def) = Denote.reduce_all env (evm, def) (* rd *) in
	let trm = TermReify.quote_term env def in
	ignore(Declare.declare_definition ~kind:Decl_kinds.Definition
                                          name (trm, Univ.ContextSet.empty)) ]
END;;

VERNAC COMMAND EXTEND Make_recursive CLASSIFIED AS SIDEFF
    | [ "Quote" "Recursively" "Definition" ident(name) ":=" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
	let def = Constrintern.interp_constr env evm def in
	let trm = TermReify.quote_term_rec env (fst def) in
	ignore(Declare.declare_definition 
	  ~kind:Decl_kinds.Definition name
	  (trm, (* No new universe constraints can be generated by typing the AST *)
           Univ.ContextSet.empty)) ]
END;;

VERNAC COMMAND EXTEND Unquote_vernac CLASSIFIED AS SIDEFF
    | [ "Make" "Definition" ident(name) ":=" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
	let def = Constrintern.interp_constr env evm def in
	let trm = Denote.denote_term (fst def) in
	let result = Constrextern.extern_constr true env evm (EConstr.of_constr trm) in
	declare_definition name
	  (Decl_kinds.Global, false, Decl_kinds.Definition)
	  [] None result None (Lemmas.mk_hook (fun _ _ -> ())) ]
END;;

VERNAC COMMAND EXTEND Unquote_inductive CLASSIFIED AS SIDEFF
    | [ "Make" "Inductive" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
  Denote.declare_interpret_inductive env evm def ]
END;;

VERNAC COMMAND EXTEND Run_program CLASSIFIED AS SIDEFF
    | [ "Run" "TemplateProgram" constr(def) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
  Denote.run_template_program env evm def ]
END;;

VERNAC COMMAND EXTEND Make_tests CLASSIFIED AS QUERY
(*
    | [ "Make" "Definitions" tactic(t) ] ->
      [ (** [t] returns a [list (string * term)] **)
	assert false ]
*)
    | [ "Test" "Quote" constr(c) ] ->
      [ check_inside_section () ;
	let (evm,env) = Lemmas.get_current_context () in
	let c = Constrintern.interp_constr env evm c in
	let result = TermReify.quote_term env (fst c) in
(* DEBUGGING
	let back = TermReify.denote_term result in
	Format.eprintf "%a\n" pp_constr result ;
	Format.eprintf "%a\n" pp_constr back ;
	assert (Term.eq_constr c back) ;
*)
        Feedback.msg_notice (Printer.pr_constr result) ;
	() ]
END;;
