
open Sexplib.Conv

type ret = [ `Warning of string
           | `Received_error of string
           | `Received of string
           | `Established_encrypted_session
           | `Received_encrypted of string ]

type keyblock = {
  ssid : Cstruct.t ;
  c    : Cstruct.t ;
  c'   : Cstruct.t ;
  m1   : Cstruct.t ;
  m2   : Cstruct.t ;
  m1'  : Cstruct.t ;
  m2'  : Cstruct.t ;
} with sexp

type dh_params = (Nocrypto.Dh.secret * Cstruct.t) with sexp

type encryption_keys = {
  dh : dh_params ;
  previous_dh : dh_params ;
  our_keyid : int32 ;
  our_ctr : int64 ;
  gy : Cstruct.t ;
  previous_gy : Cstruct.t ;
  their_keyid : int32 ;
  their_ctr : int64 ;
} with sexp

type message_state = [
  | `MSGSTATE_PLAINTEXT
  | `MSGSTATE_ENCRYPTED of encryption_keys
  | `MSGSTATE_FINISHED
] with sexp

let message_state_to_string = function
  | `MSGSTATE_PLAINTEXT   -> "plain"
  | `MSGSTATE_ENCRYPTED _ -> "encrypted"
  | `MSGSTATE_FINISHED    -> "finished"

type auth_state =
  | AUTHSTATE_NONE
  | AUTHSTATE_AWAITING_DHKEY of Cstruct.t * Cstruct.t * dh_params * Cstruct.t
  | AUTHSTATE_AWAITING_REVEALSIG of dh_params * Cstruct.t
  | AUTHSTATE_AWAITING_SIG of Cstruct.t * keyblock * dh_params * Cstruct.t
with sexp

let auth_state_to_string = function
  | AUTHSTATE_NONE                 -> "none"
  | AUTHSTATE_AWAITING_DHKEY _     -> "awaiting dh key"
  | AUTHSTATE_AWAITING_REVEALSIG _ -> "awaiting reveal signature"
  | AUTHSTATE_AWAITING_SIG _       -> "awaiting signature"

type policy = [
  | `REQUIRE_ENCRYPTION
  | `SEND_WHITESPACE_TAG
  | `WHITESPACE_START_AKE
  | `ERROR_START_AKE
] with sexp

let policy_to_string = function
  | `REQUIRE_ENCRYPTION   -> "require encryption"
  | `SEND_WHITESPACE_TAG  -> "send whitespace tag"
  | `WHITESPACE_START_AKE -> "whitespace starts key exchange"
  | `ERROR_START_AKE      -> "error starts key exchange"

let policies = [ `REQUIRE_ENCRYPTION ; `SEND_WHITESPACE_TAG ; `WHITESPACE_START_AKE ; `ERROR_START_AKE ]

type version = [ `V2 | `V3 ] with sexp

let version_to_string = function
  | `V2 -> "Version 2"
  | `V3 -> "Version 3"

let versions = [ `V2 ; `V3 ]

type config = {
  policies : policy list ;
  versions : version list ;
  dsa      : Nocrypto.Dsa.priv ;
} with sexp

type state = {
  message_state : message_state ;
  auth_state    : auth_state ;
} with sexp

type session = {
  instances : (int32 * int32) option ;
  version : version ;
  state : state ;
  config : config ;
  their_dsa : Nocrypto.Dsa.pub option ;
  ssid : Cstruct.t ;
  high : bool ;
} with sexp

let session_to_string s =
  let instances = match s.instances with
    | None -> ""
    | Some (x, y) -> " instances: " ^ (Int32.to_string x) ^ ", " ^ (Int32.to_string y)
  in
  let version =
    if
      s.state.message_state = `MSGSTATE_PLAINTEXT &&
      s.state.auth_state = AUTHSTATE_NONE
    then
      ""
    else
      (version_to_string s.version) ^ " "
  in
  let auth_state =
    if s.state.message_state = `MSGSTATE_PLAINTEXT then
      ""
    else
      " (auth " ^ (auth_state_to_string s.state.auth_state) ^ ")"
  in
  "OTR " ^ version ^
  "state: " ^ (message_state_to_string s.state.message_state) ^ auth_state ^
  instances

let dsa0 =
  let emp = Cstruct.create 0 in
  Nocrypto.Dsa.priv ~p:emp ~q:emp ~gg:emp ~x:emp ~y:emp

let default_config =
  { policies = [ `REQUIRE_ENCRYPTION ; `WHITESPACE_START_AKE ] ;
    versions = [ `V3 ; `V2 ] ;
    dsa = dsa0 }

let (<?>) ma b = match ma with None -> b | Some a -> a

let new_session config () =
  let state = { message_state = `MSGSTATE_PLAINTEXT ; auth_state = AUTHSTATE_NONE } in
  { instances = None ; version = `V3 ; state ; config ; their_dsa = None ; ssid = Cstruct.create 0 ; high = false }

let empty_session ?policies ?versions ~dsa () =
  let def = default_config in
  let policies = policies <?> def.policies in
  let versions = versions <?> def.versions in
  let config = { policies ; versions ; dsa } in
  new_session config ()


let reset_session ctx =
  empty_session ~policies:ctx.config.policies ~versions:ctx.config.versions ~dsa:ctx.config.dsa ()
