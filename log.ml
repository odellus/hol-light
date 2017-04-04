(* ========================================================================= *)
(* Tactic logging machinery (for machine learning use)                       *)
(*                                                                           *)
(*                  (c) Copyright, Google Inc. 2017                          *)
(* ========================================================================= *)

set_jrh_lexer;;
open List;;
open Fusion;;
open Basics;;
open Printer;;
open Equal;;
open Drule;;

type goal = (string * thm) list * term;;

type justification = instantiation -> (thm * thm proof_log) list -> thm * thm proof_log

and goalstate = (term list * instantiation) * goal list * justification

and tactic = goal -> goalstate

and thm_tactic = thm -> tactic

(* 'a = thm at first, then src after finalization *)
and 'a tactic_log =
  (* Goes away in final proof logs *)
  | Fake_log
  (* tactic *)
  | Abs_tac_log
  | Mk_comb_tac_log
  | Disch_tac_log
  | Eq_tac_log
  | Conj_tac_log
  | Disj1_tac_log
  | Disj2_tac_log
  | Refl_tac_log
  | Itaut_tac_log
  | Cheat_tac_log
  | Ants_tac_log
  | Raw_pop_tac_log of int
  (* thm_tactic *)
  | Label_tac_log of string * 'a
  | Accept_tac_log of 'a
  | Mp_tac_log of 'a
  | Disj_cases_tac_log of 'a
  | Contr_tac_log of 'a
  | Match_accept_tac_log of 'a
  | Match_mp_tac_log of 'a
  | Freeze_then_log of 'a
  | Backchain_tac_log of 'a
  | Imp_subst_tac_log of 'a
  (* term -> tactic *)
  | Undisch_tac_log of term
  | X_gen_tac_log of term
  | Exists_tac_log of term
  | X_meta_exists_tac_log of term
  | Raw_subgoal_tac_log of term
  (* other *)
  | Conv_tac_log of conv
  | Spec_tac_log of term * term
  | X_choose_tac_log of term * 'a
  | Conjuncts_then2_log of thm_tactic * thm_tactic * 'a
  | Unify_accept_tac_log of term list * 'a
  | Trans_tac_log of 'a * term
  | Asm_meson_tac_log of 'a list
  | Asm_metis_tac_log of 'a list
  | Rewrite_tac_log of rewrite_type * 'a list

and rewrite_type =
  | Pure_rewrite_type
  | Rewrite_type
  | Pure_once_rewrite_type
  | Once_rewrite_type

and 'a proof_log = Proof_log of goal * 'a tactic_log * 'a proof_log list;;

type src =
  | Premise_src of thm  (* A theorem that existed before this proof *)
  | Hypot_src of int * int  (* (n,k) is the kth hypothesis, n steps from the tree root *)
  | Conj_left_src of src  (* x in `x /\ y` *)
  | Conj_right_src of src  (* y in `x /\ y` *)
  | Assume_src of term  (* Generated by ASSUME tm *)
  | Unknown_src

(* ------------------------------------------------------------------------- *)
(* Replace the logging part of a tactic *)
(* ------------------------------------------------------------------------- *)

let replace_tactic_log : thm tactic_log -> tactic -> tactic =
  fun log tac g ->
    let mvs, gl, just = tac g in
    mvs, gl, fun i l -> fst (just i l), Proof_log (g,log,map snd l)

let add_tactic_log : thm tactic_log -> tactic -> tactic =
  fun log tac g ->
    let mvs, gl, just = tac g in
    mvs, gl, fun i l ->
      let th,log' = just i l in
      th, Proof_log (g, log, [log'])

(* ------------------------------------------------------------------------- *)
(* Machinery defined later, but needed in tactics.ml                         *)
(* ------------------------------------------------------------------------- *)

let replay_proof_log_ref : (src proof_log -> tactic) option ref = ref None
let finalize_proof_log_ref : (int -> thm proof_log -> src proof_log) option ref = ref None

let replay_proof_log log = match !replay_proof_log_ref with
    Some f -> f log
  | None -> failwith "replay_proof_log_ref unset"

let finalize_proof_log before_thms log = match !finalize_proof_log_ref with
    Some f -> f before_thms log
  | None -> failwith "finalize_proof_log_ref unset"

(* ------------------------------------------------------------------------- *)
(* Parseable S-Expression printer for goals.                                 *)
(* ------------------------------------------------------------------------- *)

let sexp_goal (gl:goal) =
  let asl,w = gl in
  (* TODO(geoffreyi): Should we ignore the string tag on hypotheses? *)
  Snode [Sleaf "g"; Snode (map (fun (_,th) -> sexp_thm th) asl); sexp_term w]

(* ------------------------------------------------------------------------- *)
(* Parseable S-Expression printer for proof logs.                            *)
(* ------------------------------------------------------------------------- *)

let proof_fmt : Format.formatter option =
  try
    let filename = Sys.getenv "PROOF_LOG_OUTPUT" in
    (* TODO figure out where to close this channel. *)
    let proof_log_oc = open_out filename in
    Some Format.formatter_of_out_channel proof_log_oc
  with Not_found -> None;;


(* TODO(smloos) implement this function.
   Will need to build data structure throughout _CONV tactics. *)
let sexp_conv conv = Sleaf "Conv_printing_not_implemented";;

(* TODO(smloos) implement this function. *)
let sexp_thm_tactic th_tac = Sleaf "thm_tactic_printing_not_implemented";;

(* Statistics *)
type proof_stats = {
  tactics : (string, int) Hashtbl.t;
  mutable total_tactics : int;
  (* Each proof has tactic_count, premises *)
  mutable proof_info : (int * int) list;
}
let empty_stats () = { tactics = Hashtbl.create 40;
                       total_tactics = 0;
                       proof_info = [] }
let all_stats = empty_stats ()
let replay_stats = empty_stats ()

let print_statistics name st =
  Printf.printf "\n***** %s *****\n" name;
  List.iter (fun (name,count) -> Printf.printf "%s: %d\n" name count)
    (List.sort compare (Hashtbl.fold (fun k v l -> (k,v)::l) st.tactics []));
  let proofs = length st.proof_info in
  Printf.printf "\ntotal proofs: %d\n" proofs;
  Printf.printf "total tactics: %d\n" st.total_tactics;
  if proofs != 0 then
    let stats name counts =
      let mean = float_of_int (fold_left (+) 0 counts) /. float_of_int proofs in
      let dev = sqrt (fold_left (+.) 0. (map (fun x ->
          let s = float_of_int x -. mean in s *. s) counts) /.
          float_of_int proofs) in
      Printf.printf "%s:\n  mean %g +- %g\n  quantiles:" name mean dev;
      let sorted = List.sort compare counts in
      let quantile q = List.nth sorted (min (proofs - 1) (proofs * q / 100)) in
      List.iter (fun q -> Printf.printf " %d%%:%d" q (quantile q))
                [0;10;20;30;40;50;60;70;80;90;100];
      Printf.printf "\n" in
    stats "tactics per proof" (map (fun (t,_) -> t) st.proof_info);
    stats "premises per proof" (map (fun (_,t) -> t) st.proof_info);
    Printf.printf "total thm objects: %d\n" (thm_count ())

let tactic_name taclog =
  match taclog with
    Fake_log -> "Fake_log"
  | Label_tac_log _ -> "Label_tac_log"
  | Accept_tac_log _ -> "Accept_tac_log"
  | Conv_tac_log _ -> "Conv_tac_log"
  | Abs_tac_log -> "Abs_tac_log"
  | Mk_comb_tac_log -> "Mk_comb_tac_log"
  | Disch_tac_log -> "Disch_tac_log"
  | Mp_tac_log _ -> "Mp_tac_log"
  | Eq_tac_log -> "Eq_tac_log"
  | Undisch_tac_log _ -> "Undisch_tac_log"
  | Spec_tac_log _ -> "Spec_tac_log"
  | X_gen_tac_log _ -> "X_gen_tac_log"
  | X_choose_tac_log _ -> "X_choose_tac_log"
  | Exists_tac_log _ -> "Exists_tac_log"
  | Conj_tac_log -> "Conj_tac_log"
  | Disj1_tac_log -> "Disj1_tac_log"
  | Disj2_tac_log -> "Disj2_tac_log"
  | Disj_cases_tac_log _ -> "Disj_cases_tac_log"
  | Contr_tac_log _ -> "Contr_tac_log"
  | Match_accept_tac_log _ -> "Match_accept_tac_log"
  | Match_mp_tac_log _ -> "Match_mp_tac_log"
  | Conjuncts_then2_log _ -> "Conjuncts_then2_log"
  | Raw_subgoal_tac_log _ -> "Raw_subgoal_tac_log"
  | Freeze_then_log _ -> "Freeze_then_log"
  | X_meta_exists_tac_log _ -> "X_mpeta_exists_tac_log"
  | Backchain_tac_log _ -> "Backchain_tac_log"
  | Imp_subst_tac_log _ -> "Imp_subst_tac_log"
  | Unify_accept_tac_log _ -> "Unify_accept_tac_log"
  | Refl_tac_log -> "Refl_tac_log"
  | Trans_tac_log _ -> "Trans_tac_log"
  | Itaut_tac_log -> "Itaut_tac_log"
  | Cheat_tac_log -> "Cheat_tac_log"
  | Ants_tac_log -> "Ants_tac_log"
  | Raw_pop_tac_log _ -> "Raw_pop_tac_log"
  | Asm_meson_tac_log _ -> "Asm_meson_tac_log"
  | Asm_metis_tac_log _ -> "Asm_metis_tac_log"
  | Rewrite_tac_log (ty,_) -> match ty with
      Pure_rewrite_type -> "Pure_rewrite_tac_log"
    | Rewrite_type -> "Rewrite_tac_log"
    | Pure_once_rewrite_type -> "Pure_once_rewrite_tac_log"
    | Once_rewrite_type -> "Once_rewrite_tac_log"

let rec sexp_src src = match src with
  | Premise_src th -> Snode [Sleaf "Premise_src"; sexp_thm th]
  | Hypot_src (n,k) -> Snode [Sleaf "Hypot_src"; Sleaf (string_of_int n); Sleaf (string_of_int k)]
  | Conj_left_src s -> Snode [Sleaf "Conj_left_src"; sexp_src s]
  | Conj_right_src s -> Snode [Sleaf "Conj_right_src"; sexp_src s]
  | Assume_src tm -> Snode [Sleaf "Assume_src"; sexp_term tm]
  | Unknown_src -> Snode [Sleaf "Unknown_src"]

let sexp_tactic_log f taclog =
  let name = Sleaf (tactic_name taclog) in
  match taclog with
    (* tactic *)
      Fake_log
    | Abs_tac_log
    | Mk_comb_tac_log
    | Disch_tac_log
    | Eq_tac_log
    | Conj_tac_log
    | Disj1_tac_log
    | Disj2_tac_log
    | Refl_tac_log
    | Itaut_tac_log
    | Cheat_tac_log
    | Ants_tac_log -> Snode [name]
    (* thm_tactic *)
    | Accept_tac_log th
    | Mp_tac_log th
    | Disj_cases_tac_log th
    | Contr_tac_log th
    | Match_accept_tac_log th
    | Match_mp_tac_log th
    | Backchain_tac_log th
    | Imp_subst_tac_log th -> Snode [name; f th]
    (* term -> tactic *)
    | Undisch_tac_log tm
    | X_gen_tac_log tm
    | Exists_tac_log tm
    | Raw_subgoal_tac_log tm
    | X_meta_exists_tac_log tm -> Snode [name; sexp_term tm]
    (* other *)
    | Label_tac_log (st, th) -> Snode [name; Sleaf st; f th]
    | Conv_tac_log c -> Snode [name; sexp_conv c]
    | Spec_tac_log (tm1, tm2) -> Snode [name; sexp_term tm1; sexp_term tm2]
    | X_choose_tac_log (tm, th) -> Snode [name; sexp_term tm; f th]
    | Conjuncts_then2_log (thm_tac1, thm_tac2, th) ->
        Snode [name; sexp_thm_tactic thm_tac1; sexp_thm_tactic thm_tac2; f th]
    | Freeze_then_log th -> Snode [name; f th]
    | Unify_accept_tac_log (tml, th) -> Snode [name; Snode (map sexp_term tml); f th]
    | Trans_tac_log (th,tm) -> Snode [name; f th; sexp_term tm]
    | Raw_pop_tac_log n -> Snode [name; Sleaf (string_of_int n)]
    | Asm_meson_tac_log thl
    | Asm_metis_tac_log thl
    | Rewrite_tac_log (_,thl) -> Snode [name; Snode (map f thl)]

let rec sexp_proof_log f (Proof_log (gl, taclog, logl)) =
  Snode [Sleaf "p"; sexp_goal gl; sexp_tactic_log f taclog; Snode (map (sexp_proof_log f) logl)]

let referenced_thms plog =
  let seen : (int, unit) Hashtbl.t = Hashtbl.create 1 in
  let rec visit src = match src with
      Premise_src th -> Hashtbl.replace seen (thm_id th) ()
    | Conj_left_src s -> visit s
    | Conj_right_src s -> visit s
    | Hypot_src _ | Assume_src _ | Unknown_src -> () in
  let rec visit_plog (Proof_log (_,tac,logs)) =
    visit_tac tac;
    List.iter visit_plog logs
  and visit_tac tac = match tac with
    (* 0 thms *)
    | Fake_log
    | Conv_tac_log _
    | Abs_tac_log
    | Mk_comb_tac_log
    | Disch_tac_log
    | Eq_tac_log
    | Undisch_tac_log _
    | Spec_tac_log _
    | X_gen_tac_log _
    | Exists_tac_log _
    | Conj_tac_log
    | Disj1_tac_log
    | Disj2_tac_log
    | Raw_subgoal_tac_log _
    | X_meta_exists_tac_log _
    | Refl_tac_log
    | Itaut_tac_log
    | Cheat_tac_log
    | Ants_tac_log
    | Raw_pop_tac_log _ -> ()
    (* 1 thm *)
    | Label_tac_log (_,th)
    | Accept_tac_log th
    | Mp_tac_log th
    | X_choose_tac_log (_,th)
    | Disj_cases_tac_log th
    | Contr_tac_log th
    | Match_accept_tac_log th
    | Match_mp_tac_log th
    | Conjuncts_then2_log (_,_,th)
    | Freeze_then_log th
    | Backchain_tac_log th
    | Imp_subst_tac_log th
    | Unify_accept_tac_log (_,th)
    | Trans_tac_log (th,_) -> visit th
    (* thm list *)
    | Asm_meson_tac_log thl
    | Asm_metis_tac_log thl
    | Rewrite_tac_log (_,thl) -> List.iter visit thl
  in
    visit_plog plog;
    Hashtbl.fold (fun i () l -> i :: l) seen []

let add_proof_stats st plog =
    let rec loop (Proof_log (gl, taclog, logl)) =
      let name = tactic_name taclog in
      let count = try Hashtbl.find st.tactics name with Not_found -> 0 in
      Hashtbl.replace st.tactics name (succ count);
      st.total_tactics <- succ st.total_tactics;
      List.iter loop logl in
  let before_tactics = st.total_tactics in
  loop plog;
  let after_tactics = st.total_tactics in
  let thl = referenced_thms plog in
  st.proof_info <- (after_tactics - before_tactics, length thl) :: st.proof_info
