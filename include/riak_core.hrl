-ifdef(namespaced_types).
-type riak_core_dict() :: dict:dict().
-type riak_core_set() :: sets:set().
-else.
-type riak_core_dict() :: dict().
-type riak_core_set() :: set().
-endif.

-define(CAPS, '$riak_capabilities').
