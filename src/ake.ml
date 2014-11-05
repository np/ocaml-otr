
open State

(* Monadic control-flow core. *)
type error = string
include Control.Or_error_make (struct type err = error end)
exception Handshake_error of error
let raise_unknown msg = raise (Handshake_error msg)

let instance_tag () =
  (* 32 bit random, >= 0x00000100 *)
  let tag = Cstruct.BE.get_uint32 (Nocrypto.Rng.generate 4) 0 in
  Int32.(logor tag 0x100l)

let select_version ours theirs =
  let test v = List.mem v theirs in
  match List.filter test ours with
  | v::_ -> Some v
  | [] -> None

let instances = function
  | `V2 -> None
  | `V3 -> Some (0l, instance_tag ())

(* authentication handshake *)
let dh_commit ctx their_versions =
  match select_version ctx.config.versions their_versions with
  | None -> (* send error message no matching version! *) assert false
  | Some version ->
    let dh_secret, gx = Crypto.gen_dh_secret () in
    let r = Crypto.gen_symmetric_key () in
    let gxmpi = Builder.encode_data gx in
    let gxmpi' = Crypto.crypt ~key:r ~ctr:(Crypto.ctr0 ()) gxmpi in
    let h = Crypto.hash gxmpi in
    let instances = instances version in
    let dh_commit = Builder.dh_commit version instances gxmpi' h in
    let auth_state = AUTHSTATE_AWAITING_DHKEY (dh_commit, h, (dh_secret, gx), r)
    and message_state = MSGSTATE_PLAINTEXT in (* not entirely sure about this.. *)
    let state = { auth_state ; message_state } in
    ({ ctx with version ; instances ; state }, [dh_commit])

let dh_key_await_revealsig ctx buf =
  let dh_secret, gx = Crypto.gen_dh_secret () in
  let out = Builder.dh_key ctx.version ctx.instances gx in
  let state = { ctx.state with auth_state = AUTHSTATE_AWAITING_REVEALSIG ((dh_secret, gx), buf) } in
  ({ ctx with state }, out)

let (<+>) = Nocrypto.Uncommon.Cs.append

let check_key_reveal_sig ctx (dh_secret, gx) r gy =
  match Parser.parse_gy gy with
  | Parser.Error _ -> assert false
  | Parser.Ok gy ->
    let shared_secret = Crypto.dh_shared dh_secret gy in
    let keys = Crypto.derive_keys shared_secret in
    let { c ; m1 ; m2 } = keys in
    let keyidb = 1l in
    let pubb = Crypto.OtrDsa.priv_to_wire ctx.config.dsa in
    let sigb =
      let gxmpi = Builder.encode_data gx
      and gympi = Builder.encode_data gy
      in
      let mb = Crypto.mac ~key:m1 [ gxmpi ; gympi ; pubb ; Builder.encode_int keyidb ] in
      Crypto.OtrDsa.signature ~key:ctx.config.dsa mb
    in
    let enc_sig =
      let xb = pubb <+> Builder.encode_int keyidb <+> sigb in
      Crypto.crypt ~key:c ~ctr:(Crypto.ctr0 ()) xb
    in
    let mac = Crypto.mac160 ~key:m2 enc_sig in
    let reveal_sig = Builder.reveal_signature ctx.version ctx.instances r enc_sig mac in
    let state = { ctx.state with auth_state = AUTHSTATE_AWAITING_SIG (reveal_sig, keys, (dh_secret, gx), gy) } in
    ({ ctx with state }, reveal_sig)

let check_reveal_send_sig ctx (dh_secret, gy) dh_commit buf =
  match Parser.parse_reveal buf with
  | Parser.Error _ -> assert false
  | Parser.Ok (r, enc_data, mac) ->
    let gx =
      match Parser.parse_dh_commit dh_commit with
      | Parser.Error _ -> assert false
      | Parser.Ok (gxenc, hgx) ->
        let gx = Crypto.crypt ~key:r ~ctr:(Crypto.ctr0 ()) gxenc in
        let hgx' = Crypto.hash gx in
        assert (Nocrypto.Uncommon.Cs.equal hgx hgx') ;
        Parser.(match parse_gy gx with
            | Error _ -> assert false
            | Ok gx -> gx )
    in
    let shared_secret = Crypto.dh_shared dh_secret gx in
    let { ssid ; c ; c' ; m1 ; m2 ; m1' ; m2' } = Crypto.derive_keys shared_secret in
    let mac' = Crypto.mac160 ~key:m2 enc_data in
    assert (Nocrypto.Uncommon.Cs.equal mac mac') ;
    let pubb, keyidb =
      let xb = Crypto.crypt ~key:c ~ctr:(Crypto.ctr0 ()) enc_data in
      (* split into pubb, keyidb, sigb *)
      match Parser.parse_signature_data xb with
      | Parser.Error _ -> assert false
      | Parser.Ok ((p,q,gg,y), keyidb, sigb) ->
        let pubb = Nocrypto.Dsa.pub ~p ~q ~gg ~y in
        let gxmpi = Builder.encode_data gx
        and gympi = Builder.encode_data gy
        in
        let mb = Crypto.mac ~key:m1 [ gxmpi ; gympi ; Crypto.OtrDsa.to_wire pubb ; Builder.encode_int keyidb ] in
        assert (Crypto.OtrDsa.verify ~key:pubb sigb mb) ;
        Printf.printf "PUBB their fingerprint" ; Cstruct.hexdump (Crypto.OtrDsa.fingerprint pubb) ;
        (pubb, keyidb)
    in
    (* pick keyida *)
    let keyida = 1l in
    let puba = Crypto.OtrDsa.priv_to_wire ctx.config.dsa in
    let siga =
      let gxmpi = Builder.encode_data gx
      and gympi = Builder.encode_data gy
      in
      let ma = Crypto.mac ~key:m1' [ gympi ; gxmpi ; puba ; Builder.encode_int keyida ] in
      Crypto.OtrDsa.signature ~key:ctx.config.dsa ma
    in
    let enc =
      let xa = puba <+> Builder.encode_int keyida <+> siga in
      Crypto.crypt ~key:c' ~ctr:(Crypto.ctr0 ()) xa
    in
    let m = Crypto.mac160 ~key:m2' enc in
    let keys =
      let dh = Crypto.gen_dh_secret ()
      and previous_y = Cstruct.create 0
      in
      { dh ; previous_dh = (dh_secret, gy) ; our_keyid = 2l ; our_ctr = 0L ;
        y = gx ; previous_y ; their_keyid = keyida ; their_ctr = 0L }
    in
    let state = {
      auth_state = AUTHSTATE_NONE ;
    message_state = MSGSTATE_ENCRYPTED keys
    } in
    ({ ctx with state ; their_dsa = Some pubb ; ssid },
     Builder.signature ctx.version ctx.instances enc m)

let check_sig ctx { ssid ; c' ; m1' ; m2' } (dh_secret, gx) gy signature =
  (* decrypt signature, verify it and macs *)
  let enc_data =
    match Parser.decode_data signature with
    | Parser.Error _ -> assert false
    | Parser.Ok (enc_data, mac) ->
      assert (Cstruct.len mac = 20) ;
      let mymac = Crypto.mac160 ~key:m2' enc_data in
      assert (Nocrypto.Uncommon.Cs.equal mac mymac) ;
      enc_data
  in
  let puba, keyida =
    let dec = Crypto.crypt ~key:c' ~ctr:(Crypto.ctr0 ()) enc_data in
    (* split into puba keyida siga(Ma) *)
    match Parser.parse_signature_data dec with
    | Parser.Error _ -> assert false
    | Parser.Ok ((p, q, gg, y), keyida, siga) ->
      let puba = Nocrypto.Dsa.pub ~p ~q ~gg ~y in
      let gxmpi = Builder.encode_data gx
      and gympi = Builder.encode_data gy
      in
      let ma = Crypto.mac ~key:m1' [ gympi ; gxmpi ; Crypto.OtrDsa.to_wire puba ; Builder.encode_int keyida ] in
      assert (Crypto.OtrDsa.verify ~key:puba siga ma) ;
      Printf.printf "PUBA their fingerprint" ; Cstruct.hexdump (Crypto.OtrDsa.fingerprint puba) ;
      (puba, keyida)
  in
  let keys =
    let dh = Crypto.gen_dh_secret ()
    and previous_y = Cstruct.create 0
    in
    { dh ; previous_dh = (dh_secret, gx) ; our_keyid = 2l ; our_ctr = 0L ;
      y = gy ; previous_y ; their_keyid = keyida ; their_ctr = 0L }
  in
  let state = {
    auth_state = AUTHSTATE_NONE ;
    message_state = MSGSTATE_ENCRYPTED keys
  } in
  { ctx with state ; their_dsa = Some puba ; ssid }

let handle_auth ctx bytes =
  let open Packet in
  match Parser.parse_header bytes with
    | Parser.Ok  (version, typ, instances, buf) ->
      let ctx = match ctx.state.auth_state with
        | AUTHSTATE_NONE -> { ctx with version }
        | _ -> assert (version = ctx.version) ; ctx
      in
      let ctx = match version, instances, ctx.instances with
        | `V3, Some (yoursend, yourrecv), Some (mysend, myrecv) when mysend = 0l ->
          assert ((yourrecv = myrecv) && (Int32.shift_right_logical yoursend 8 > 0l)) ;
          { ctx with instances = Some (yoursend, myrecv) }
        | `V3, Some (yoursend, yourrecv), Some (mysend, myrecv) ->
          assert ((yourrecv = myrecv) && (yoursend = mysend)) ;
          ctx
        | `V3, Some (yoursend, yourrecv), None ->
          if Int32.shift_right_logical yourrecv 8 = 0l then
            let myinstance = instance_tag () in
            { ctx with instances = Some (yoursend, myinstance) }
          else (* other side has an encrypted session with us, but we do not *)
            ctx
        | `V2, _ , _ -> ctx
        | _ -> Printf.printf "wonky instances\n%!" ; assert false
      in
      begin
        match typ, ctx.state.auth_state with
        | DH_COMMIT, AUTHSTATE_NONE ->
          (* send dh_key,  go to AWAITING_REVEALSIG *)
          let ctx, dh_key = dh_key_await_revealsig ctx buf in
          (ctx, [dh_key], None)
        | DH_COMMIT, AUTHSTATE_AWAITING_DHKEY (dh_c, h, _, _) ->
          (* compare hash *)
          let their_hash = Cstruct.sub buf (Cstruct.len buf - 32) 32 in
          if Crypto.mpi_gt h their_hash then
            (ctx, [dh_c], None)
          else
            let ctx, dh_key = dh_key_await_revealsig ctx buf in
            (ctx, [dh_key], None)
        | DH_COMMIT, AUTHSTATE_AWAITING_REVEALSIG ((dh_secret, gx), _) ->
          (* use this dh_commit ; resend dh_key *)
          let state = { ctx.state with auth_state = AUTHSTATE_AWAITING_REVEALSIG ((dh_secret, gx), buf) } in
          let out = Builder.dh_key ctx.version ctx.instances gx in
          ({ ctx with state }, [out], None)
        | DH_COMMIT, AUTHSTATE_AWAITING_SIG _ ->
          (* send dh_key, go to AWAITING_REVEALSIG *)
          let ctx, dh_key = dh_key_await_revealsig ctx buf in
          (ctx, [dh_key], None)

        | DH_KEY, AUTHSTATE_AWAITING_DHKEY (_, _, dh_params, r) ->
          (* reveal_sig -> AUTHSTATE_AWAITING_SIG *)
          let ctx, reveal = check_key_reveal_sig ctx dh_params r buf in
          (ctx, [reveal], None)

        | DH_KEY, AUTHSTATE_AWAITING_SIG (reveal_sig, _, _, gy) ->
          (* same dh_key? -> retransmit REVEAL_SIG *)
          if Nocrypto.Uncommon.Cs.equal gy buf then
            (ctx, [reveal_sig], None)
          else
            (ctx, [], None)

        | REVEAL_SIGNATURE, AUTHSTATE_AWAITING_REVEALSIG (dh_params, dh_commit)  ->
          (* do work, send signature -> AUTHSTATE_NONE, MSGSTATE_ENCRYPTED *)
          let ctx, out = check_reveal_send_sig ctx dh_params dh_commit buf in
          (ctx, [out], None)

        | SIGNATURE, AUTHSTATE_AWAITING_SIG (_, keys, dh_params, gy) ->
          (* decrypt signature, verify sig + macs -> AUTHSTATE_NONE, MSGSTATE_ENCRYPTED *)
          let ctx = check_sig ctx keys dh_params gy buf in
          (ctx, [], None)

        | DATA, _ ->
          Printf.printf "received data message while in plaintext mode, ignoring\n" ;
          (ctx, [], None)

        | _ -> (ctx, [], None)
      end
    | Parser.Error _ -> (ctx, [], None)
