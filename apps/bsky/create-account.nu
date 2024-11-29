#!/usr/bin/env nu

let pds_hostname = "pds.0xf.fr"
let admin_password = kubectl get -n bsky secrets/bluesky-pds-secrets -ojson | from json | get data.adminPassword | decode base64 | decode

let code_resp = http post --user admin --password $admin_password https://($pds_hostname)/xrpc/com.atproto.server.createInviteCode -t application/json {useCount: 1}
let password = head -c 20 /dev/urandom | encode base32hex | str trim -r

let user_info = {
  "email": "netop@0xf.fr",
  "handle": "netop.pds.0xf.fr",
  "password": $password,
  "inviteCode": $code_resp.code
}

let create_resp = http post https://($pds_hostname)/xrpc/com.atproto.server.createAccount -t application/json $user_info

print $"Login at https://bsky.app with \"($user_info.handle)\", password \"($user_info.password)\" and server \"($pds_hostname)\""