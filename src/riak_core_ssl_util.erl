%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Various ssl functions for the Riak Core Connection Manager
-module(riak_core_ssl_util).

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

-export([maybe_use_ssl/1,
         upgrade_client_to_ssl/2,
         upgrade_server_to_ssl/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


maybe_use_ssl(App) ->
    SSLOpts = [
        {certfile, app_helper:get_env(App, certfile, undefined)},
        {keyfile, app_helper:get_env(App, keyfile, undefined)},
        {cacerts, load_certs(app_helper:get_env(App, cacertdir, undefined))},
        {depth, app_helper:get_env(App, ssl_depth, 1)},
        {verify_fun, {fun verify_ssl/3,
                {App, get_my_common_name(app_helper:get_env(App, certfile,
                                                       undefined))}}},
        {verify, verify_peer},
        {fail_if_no_peer_cert, true},
        {secure_renegotiate, true} %% both sides are erlang, so we can force this
    ],
    Enabled = app_helper:get_env(App, ssl_enabled, false) == true,
    case validate_ssl_config(App, Enabled, SSLOpts) of
        true ->
            SSLOpts;
        {error, Reason} ->
            lager:error("Error, invalid SSL configuration: ~s", [Reason]),
            false;
        false ->
            %% not all the SSL options are configured, use TCP
            false
    end.


validate_ssl_config(_App, false, _) ->
    %% ssl is disabled
    false;
validate_ssl_config(_App, true, []) ->
    %% all options validated
    true;
validate_ssl_config(App, true, [{certfile, CertFile}|Rest]) ->
    case filelib:is_regular(CertFile) of
        true ->
            validate_ssl_config(App, true, Rest);
        false ->
            {error, lists:flatten(io_lib:format("Certificate ~p is not a file",
                                                [CertFile]))}
    end;
validate_ssl_config(App, true, [{keyfile, KeyFile}|Rest]) ->
    case filelib:is_regular(KeyFile) of
        true ->
            validate_ssl_config(App, true, Rest);
        false ->
            {error, lists:flatten(io_lib:format("Key ~p is not a file",
                                                [KeyFile]))}
    end;
validate_ssl_config(App, true, [{cacerts, CACerts}|Rest]) ->
    case CACerts of
        undefined ->
            {error, lists:flatten(
                    io_lib:format("CA cert dir ~p is invalid",
                                  [app_helper:get_env(App, cacertdir,
                                                      undefined)]))};
        [] ->
            {error, lists:flatten(
                    io_lib:format("Unable to load any CA certificates from ~p",
                                  [app_helper:get_env(App, cacertdir,
                                                      undefined)]))};
        Certs when is_list(Certs) ->
            validate_ssl_config(App, true, Rest)
    end;
validate_ssl_config(App, true, [_|Rest]) ->
    validate_ssl_config(App, true, Rest).

upgrade_client_to_ssl(Socket, App) ->
    case maybe_use_ssl(App) of
        false ->
            {error, no_ssl_config};
        Config ->
            ssl:connect(Socket, Config)
    end.

upgrade_server_to_ssl(Socket, App) ->
    case maybe_use_ssl(App) of
        false ->
            {error, no_ssl_config};
        Config ->
            ssl:ssl_accept(Socket, Config)
    end.

load_certs(undefined) ->
    undefined;
load_certs(CertDir) ->
    case file:list_dir(CertDir) of
        {ok, Certs} ->
            load_certs(lists:map(fun(Cert) -> filename:join(CertDir, Cert)
                    end, Certs), []);
        {error, _} ->
            undefined
    end.

load_certs([], Acc) ->
    lager:debug("Successfully loaded ~p CA certificates", [length(Acc)]),
    Acc;
load_certs([Cert|Certs], Acc) ->
    case filelib:is_dir(Cert) of
        true ->
            load_certs(Certs, Acc);
        _ ->
            lager:debug("Loading certificate ~p", [Cert]),
            load_certs(Certs, load_cert(Cert) ++ Acc)
    end.

load_cert(Cert) ->
    {ok, Bin} = file:read_file(Cert),
    case filename:extension(Cert) of
        ".der" ->
            %% no decoding necessary
            [Bin];
        _ ->
            %% assume PEM otherwise
            Contents = public_key:pem_decode(Bin),
            [DER || {Type, DER, Cipher} <- Contents,
                    Type == 'Certificate', Cipher == 'not_encrypted']
    end.

%% Custom SSL verification function for checking common names against the
%% whitelist.
verify_ssl(_, {bad_cert, _} = Reason, _) ->
    {fail, Reason};
verify_ssl(_, {extension, _}, UserState) ->
    {unknown, UserState};
verify_ssl(_, valid, UserState) ->
    %% this is the check for the CA cert
    {valid, UserState};
verify_ssl(_, valid_peer, undefined) ->
    lager:error("Unable to determine local certificate's common name"),
    {fail, bad_local_common_name};
verify_ssl(Cert, valid_peer, {App, MyCommonName}) ->
    CommonName = get_common_name(Cert),
    case string:to_lower(CommonName) == string:to_lower(MyCommonName) of
        true ->
            lager:error("Peer certificate's common name matches local "
                "certificate's common name: ~p", [CommonName]),
            {fail, duplicate_common_name};
        _ ->
            case validate_common_name(CommonName,
                    app_helper:get_env(App, peer_common_name_acl, "*")) of
                {true, Filter} ->
                    lager:info("SSL connection from ~s granted by ACL ~s",
                        [CommonName, Filter]),
                    {valid, MyCommonName};
                false ->
                    lager:error("SSL connection from ~s denied, no matching ACL",
                        [CommonName]),
                    {fail, no_acl}
            end
    end.

%% read in the configured 'certfile' and extract the common name from it
get_my_common_name(undefined) ->
    undefined;
get_my_common_name(CertFile) ->
    case catch(load_cert(CertFile)) of
        [CertBin|_] ->
            OTPCert = public_key:pkix_decode_cert(CertBin, otp),
            get_common_name(OTPCert);
        _ ->
            undefined
    end.

%% get the common name attribute out of an OTPCertificate record
get_common_name(OTPCert) ->
    %% You'd think there'd be an easier way than this giant mess, but I
    %% couldn't find one.
    {rdnSequence, Subject} = OTPCert#'OTPCertificate'.tbsCertificate#'OTPTBSCertificate'.subject,
    [Att] = [Attribute#'AttributeTypeAndValue'.value || [Attribute] <- Subject,
        Attribute#'AttributeTypeAndValue'.type == ?'id-at-commonName'],
    case Att of
        {printableString, Str} -> Str;
        {utf8String, Bin} -> binary_to_list(Bin)
    end.

%% Validate common name matches one of the configured filters. Filters can
%% have at most one '*' wildcard in the leftmost component of the hostname.
validate_common_name(_, []) ->
    false;
validate_common_name(_, "*") ->
    {true, "*"};
validate_common_name(CN, [Filter|Filters]) ->
    T1 = string:tokens(string:to_lower(CN), "."),
    T2 = string:tokens(string:to_lower(Filter), "."),
    case length(T1) == length(T2) of
        false ->
            validate_common_name(CN, Filters);
        _ ->
            case hd(T2) of
                "*" ->
                    case tl(T1) == tl(T2) of
                        true ->
                            {true, Filter};
                        _ ->
                            validate_common_name(CN, Filters)
                    end;
                _ ->
                    case T1 == T2 of
                        true ->
                            {true, Filter};
                        _ ->
                            validate_common_name(CN, Filters)
                    end
            end
    end.


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).
-endif.
