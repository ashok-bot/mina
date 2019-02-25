(* TODO: rename *)

open Core_kernel
open Snark_params
open Tick
open Coda_base
open Let_syntax

module Make (Consensus_mechanism : Consensus.S) :
  Blockchain_state_intf.S
  with module Consensus_mechanism := Consensus_mechanism = struct
  module Blockchain_state = Consensus_mechanism.Blockchain_state
  module Protocol_state = Consensus_mechanism.Protocol_state
  module Snark_transition = Consensus_mechanism.Snark_transition

  (*module Pending_coinbase_state_temp = Snark_transition.Pending_coinbase_state_temp
  module Pending_coinbase = Pending_coinbase_state_temp.Pending_coinbase*)

  module type Update_intf = sig
    module Checked : sig
      val update :
           State_hash.var * Protocol_state.var
        -> Snark_transition.var
        -> ( State_hash.var * Protocol_state.var * [`Success of Boolean.var]
           , _ )
           Checked.t
    end
  end

  module Make_update (T : Transaction_snark.Verification.S) = struct
    module Checked = struct
      (* Blockchain_snark ~old ~nonce ~ledger_snark ~ledger_hash ~timestamp ~new_hash
            Input:
              old : Blockchain.t
              old_snark : proof
              nonce : int
              work_snark : proof
              ledger_hash : Ledger_hash.t
              timestamp : Time.t
              new_hash : State_hash.t
            Witness:
              transition : Transition.t
            such that
              the old_snark verifies against old
              new = update_with_asserts(old, nonce, timestamp, ledger_hash)
              hash(new) = new_hash
              the work_snark verifies against the old.ledger_hash and new_ledger_hash
              new.timestamp > old.timestamp
              transition consensus data is valid
              new consensus state is a function of the old consensus state
      *)
      let%snarkydef update
          ((previous_state_hash, previous_state) :
            State_hash.var * Protocol_state.var)
          (transition : Snark_transition.var) :
          ( State_hash.var * Protocol_state.var * [`Success of Boolean.var]
          , _ )
          Tick.Checked.t =
        (*TODO:Deeptthi: coinbase_update in transition is finally landing here. Make the Pending_coinbase delete and update requests here*)
        let supply_increase = Snark_transition.supply_increase transition in
        let%bind `Success updated_consensus_state, consensus_state =
          Consensus_mechanism.next_state_checked ~prev_state:previous_state
            ~prev_state_hash:previous_state_hash transition supply_increase
        in
        let pending_coinbase_state =
          Snark_transition.pending_coinbase_state transition
        in
        (*TODO: Deepthi: based on the type of update, perform requests accordingly here *)
        let%bind success =
          let%bind correct_transaction_snark =
            let%bind index =
              request_witness Pending_coinbase.Index.Unpacked.typ
                As_prover.(
                  map (return ()) ~f:(fun _ ->
                      Pending_coinbase.Hash.Find_index_of_oldest_stack ))
            in
            let%bind pending_coinbase_stack_deleted =
              Pending_coinbase.Hash.get pending_coinbase_state.prev_root index
            in
            T.verify_complete_merge
              (Snark_transition.sok_digest transition)
              ( previous_state |> Protocol_state.blockchain_state
              |> Blockchain_state.snarked_ledger_hash )
              ( transition |> Snark_transition.blockchain_state
              |> Blockchain_state.snarked_ledger_hash )
              Pending_coinbase.Stack.Checked.empty
              pending_coinbase_stack_deleted supply_increase
              (*TODO:Deepthi: get coinbase stack from the delete_stack request *)
              (As_prover.return
                 (Option.value ~default:Tock.Proof.dummy
                    (Snark_transition.ledger_proof transition)))
          and ledger_hash_didn't_change =
            Frozen_ledger_hash.equal_var
              ( previous_state |> Protocol_state.blockchain_state
              |> Blockchain_state.snarked_ledger_hash )
              ( transition |> Snark_transition.blockchain_state
              |> Blockchain_state.snarked_ledger_hash )
          in
          let%bind new_pending_coinbase_hash =
            let prev_root =
              previous_state |> Protocol_state.blockchain_state
              |> Blockchain_state.pending_coinbase_hash
              (*Pending_coinbase_state_temp.prev_root pending_coinbase_state*)
            in
            let updated_stack = pending_coinbase_state.updated_stack in
            let action = pending_coinbase_state.action in
            let with_del_add () =
              let%bind with_del =
                Pending_coinbase.Hash.delete_stack prev_root
              in
              Pending_coinbase.Hash.update_stack with_del
                ~is_new_stack:Boolean.true_ ~f:(fun _ -> return updated_stack
              )
            in
            let with_del_update () =
              let%bind with_del =
                Pending_coinbase.Hash.delete_stack prev_root
              in
              Pending_coinbase.Hash.update_stack with_del
                ~is_new_stack:Boolean.false_ ~f:(fun _ -> return updated_stack
              )
            in
            let with_add () =
              Pending_coinbase.Hash.update_stack prev_root
                ~is_new_stack:Boolean.true_ ~f:(fun _ -> return updated_stack
              )
            in
            let with_update () =
              Pending_coinbase.Hash.update_stack prev_root
                ~is_new_stack:Boolean.false_ ~f:(fun _ -> return updated_stack
              )
            in
            let%bind added =
              Pending_coinbase_state_temp.Action.Checked.added action
            in
            let%bind updated =
              Pending_coinbase_state_temp.Action.Checked.updated action
            in
            let%bind del_add =
              Pending_coinbase_state_temp.Action.Checked.deleted_added action
            in
            let chain if_ b ~then_ ~else_ =
              let%bind then_ = then_ and else_ = else_ in
              if_ b ~then_ ~else_
            in
            chain Pending_coinbase.Hash.if_ added ~then_:(with_add ())
              ~else_:
                (chain Pending_coinbase.Hash.if_ updated
                   ~then_:(with_update ())
                   ~else_:
                     (chain Pending_coinbase.Hash.if_ del_add
                        ~then_:(with_del_add ()) ~else_:(with_del_update ())))
          in
          (*The tree hash obtained should be the same as the tree hash in the blockchain state which was computed outside checked. Success if that's true*)
          let%bind correct_coinbase_status =
            let new_root = pending_coinbase_state.new_root in
            Pending_coinbase.Hash.equal_var new_pending_coinbase_hash new_root
          in
          let%bind correct_snark =
            Boolean.(correct_transaction_snark || ledger_hash_didn't_change)
          in
          Boolean.all
            [correct_snark; updated_consensus_state; correct_coinbase_status]
        in
        let new_state =
          Protocol_state.create_var ~previous_state_hash
            ~blockchain_state:(Snark_transition.blockchain_state transition)
            ~consensus_state
        in
        let%bind state_triples = Protocol_state.var_to_triples new_state in
        let%bind state_partial =
          Pedersen.Checked.Section.extend Pedersen.Checked.Section.empty
            ~start:Hash_prefix.length_in_triples state_triples
        in
        let%map state_hash =
          Pedersen.Checked.Section.create
            ~acc:(`Value Hash_prefix.protocol_state.acc)
            ~support:
              (Interval_union.of_interval (0, Hash_prefix.length_in_triples))
          |> Pedersen.Checked.Section.disjoint_union_exn state_partial
          >>| Pedersen.Checked.Section.to_initial_segment_digest_exn >>| fst
        in
        (State_hash.var_of_hash_packed state_hash, new_state, `Success success)
    end
  end

  module Checked = struct
    let%snarkydef is_base_hash h =
      Field.Checked.equal
        (Field.Var.constant
           (Consensus_mechanism.genesis_protocol_state.hash :> Field.t))
        (State_hash.var_to_hash_packed h)

    let%snarkydef hash (t : Protocol_state.var) =
      Protocol_state.var_to_triples t
      >>= Pedersen.Checked.digest_triples ~init:Hash_prefix.protocol_state
      >>| State_hash.var_of_hash_packed
  end
end
