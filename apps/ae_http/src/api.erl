-module(api).
-compile(export_all).
-define(Fee, element(2, application:get_env(ae_core, tx_fee))).
-define(IP, constants:server_ip()).
-define(Port, constants:server_port()).
-include("../../ae_core/src/records.hrl").
dump_channels() ->
    channel_manager:dump().
keys_status() -> keys:status().
load_key(Pub, Priv, Brainwallet) ->
    keys:load(Pub, Priv, Brainwallet).
height() ->    
    (headers:top())#header.height.
top() ->
    TopHeader = headers:top(),
    Height = TopHeader#header.height,
    {top, TopHeader, Height}.
sign(Tx) -> keys:sign(Tx).
tx_maker0(Tx) -> 
    case keys:sign(Tx) of
	{error, locked} -> 
	    io:fwrite("your password is locked. use `keys:unlock(\"PASSWORD1234\")` to unlock it"),
	    ok;
	Stx -> tx_pool_feeder:absorb(Stx)
    end.
create_account(NewAddr, Amount) ->
    Cost = trees:dict_tree_get(governance, create_acc_tx),
    create_account(NewAddr, Amount, ?Fee + Cost).
create_account(NewAddr, Amount, Fee) ->
    Tx = create_account_tx:make_dict(NewAddr, Amount, Fee, keys:pubkey()),
    tx_maker0(Tx).
coinbase(ID) ->
    K = keys:pubkey(),
    tx_maker0(coinbase_tx:make_dict(K)).
spend(ID, Amount) ->
    K = keys:pubkey(),
    if 
	ID == K -> io:fwrite("you can't spend money to yourself\n");
	true -> 
	    B = trees:dict_tree_get(accounts, ID),
            if 
                (B == empty) ->
                    create_account(ID, Amount);
                true ->
		    Cost = trees:dict_tree_get(governance, spend),
                    spend(ID, Amount, ?Fee+Cost)
            end
    end.
spend(ID, Amount, Fee) ->
    tx_maker0(spend_tx:make_dict(ID, Amount, Fee, keys:pubkey())).
delete_account(ID) ->
    Cost = trees:dict_tree_get(governance, delete_acc_tx),
    delete_account(ID, ?Fee + Cost).
delete_account(ID, Fee) ->
    tx_maker0(delete_account_tx:make_dict(ID, keys:pubkey(), Fee)).
new_channel_tx(CID, Acc2, Bal1, Bal2, Delay) ->
    Cost = trees:dict_tree_get(governance, nc),
    new_channel_tx(CID, Acc2, Bal1, Bal2, ?Fee+Cost, Delay).
new_channel_tx(CID, Acc2, Bal1, Bal2, Fee, Delay) ->
    %the delay is how many blocks you have to wait to close the channel if your partner disappears.
    %delay is also how long you have to stop your partner from closing at the wrong state.
    Tx = new_channel_tx:make_dict(CID, keys:pubkey(), Acc2, Bal1, Bal2, Delay, Fee),
    keys:sign(Tx).
new_channel_with_server(Bal1, Bal2, Delay, Expires) ->
    new_channel_with_server(Bal1, Bal2, Delay, Expires, ?IP, ?Port).
new_channel_with_server(Bal1, Bal2, Delay, Expires, IP, Port) ->
    CID = find_id2(),
    Cost = trees:dict_tree_get(governance, nc),
    new_channel_with_server(IP, Port, CID, Bal1, Bal2, ?Fee+Cost, Delay, Expires),
    CID.
find_id2() -> find_id2(1, 1).
find_id2(_, _) ->
    <<X:256>> = crypto:strong_rand_bytes(32),
    X.
find_id(Name, Tree) ->
    find_id(Name, 1, Tree).
find_id(Name, N, Tree) ->
    case Name:get(N, Tree) of
	{_, empty, _} -> N;
	_ -> find_id(Name, N+1, Tree)
    end.
new_channel_with_server(IP, Port, CID, Bal1, Bal2, Fee, Delay, Expires) ->
    Acc1 = keys:pubkey(),
    {ok, Acc2} = talker:talk({pubkey}, IP, Port),
    Tx = new_channel_tx:make_dict(CID, Acc1, Acc2, Bal1, Bal2, Delay, Fee),
    {ok, ChannelDelay} = application:get_env(ae_core, channel_delay),
    {ok, TV} = talker:talk({time_value}, IP, Port),%We need to ask the server for their time_value.
    %make sure the customer is aware of the time_value before they click this button. Don't request time_value now, it should have been requested earlier.
    LifeSpan = Expires - api:height(),
    CFee = TV * (Delay + LifeSpan) * (Bal1 + Bal2) div 100000000,
    SPK0 = new_channel_tx:spk(Tx, ChannelDelay),
    SPK = SPK0#spk{amount = CFee},
    STx = keys:sign(Tx),
    SSPK = keys:sign(SPK),
    Msg = {new_channel, STx, SSPK, Expires},
    {ok, [SSTx, S2SPK]} = talker:talk(Msg, IP, Port),
    tx_pool_feeder:absorb(SSTx),
    channel_feeder:new_channel(Tx, S2SPK, Expires),
    ok.
pull_channel_state() ->
    pull_channel_state(?IP, ?Port).
pull_channel_state(IP, Port) ->
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    {ok, [CD, ThemSPK]} = talker:talk({spk, keys:pubkey()}, IP, Port),
    case channel_manager:read(ServerID) of
        error  -> 
            %This trusts the server and downloads a new version of the state from them. It is only suitable for testing and development. Do not use this in production.
            SPKME = CD#cd.them,
            true = testnet_sign:verify(keys:sign(ThemSPK)),
            SPK = testnet_sign:data(ThemSPK),
            SPK = testnet_sign:data(SPKME),
            true = keys:pubkey() == element(2, SPK),
            NewCD = CD#cd{me = SPK, them = ThemSPK, ssme = CD#cd.ssthem, ssthem = CD#cd.ssme},
            channel_manager:write(ServerID, NewCD);
        {ok, CD0} ->
            true = CD0#cd.live,
            SPKME = CD0#cd.me,
            Return = channel_feeder:they_simplify(ServerID, ThemSPK, CD),
            talker:talk({channel_sync, keys:pubkey(), Return}, IP, Port),
            decrypt_msgs(CD#cd.emsg),
            bet_unlock(IP, Port),
            ok
    end.
channel_state() -> 
    channel_manager:read(hd(channel_manager:keys())).
decrypt_msgs([]) ->
    [];
decrypt_msgs([{msg, _, Msg, _}|T]) ->
    [Msg|decrypt_msgs(T)];
decrypt_msgs([Emsg|T]) ->
    [Secret, Code, Amount] = keys:decrypt(Emsg),
    learn_secret(Secret, Code, Amount),
    decrypt_msgs(T).
learn_secret(Secret, Code, Amount) ->
    secrets:add(Code, Secret, Amount).
%add_secret(Code, Secret) ->
%    ok = pull_channel_state(?IP, ?Port),
%    secrets:add(Code, Secret),
%    ok = bet_unlock(?IP, ?Port).
bet_unlock(IP, Port) ->
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    [{Secrets, _SPK}] = channel_feeder:bets_unlock([ServerID]),
    teach_secrets(keys:pubkey(), Secrets, IP, Port),
    {ok, [_CD, ThemSPK]} = talker:talk({spk, keys:pubkey()}, IP, Port),
    channel_feeder:update_to_me(ThemSPK, ServerID),
    ok.
teach_secrets(_, [], _, _) -> ok;
teach_secrets(ID, [{secret, Secret, Code}|Secrets], IP, Port) ->
    talker:talk({learn_secret, ID, Secret, Code}, IP, Port),
    teach_secrets(ID, Secrets, IP, Port).
channel_spend(Amount) ->
    channel_spend(?IP, ?Port, Amount).
channel_spend(IP, Port, Amount) ->
    {ok, PeerId} = talker:talk({pubkey}, IP, Port),
    {ok, CD} = channel_manager:read(PeerId),
    OldSPK = testnet_sign:data(CD#cd.them),
    ID = keys:pubkey(),
    SPK = spk:get_paid(OldSPK, ID, -Amount), 
    Payment = keys:sign(SPK),
    M = {channel_payment, Payment, Amount},
    {ok, Response} = talker:talk(M, IP, Port),
    channel_feeder:spend(Response, -Amount),
    ok.
lightning_spend(Pubkey, Amount) ->
    {ok, LFee} = application:get_env(ae_core, lightning_fee),
    lightning_spend(?IP, ?Port, Pubkey, Amount, LFee).
lightning_spend(IP, Port, Pubkey, Amount) ->
    lightning_spend(IP, Port, Pubkey, Amount, ?Fee).
lightning_spend(IP, Port, Pubkey, Amount, Fee) ->
    {Code, SS} = secrets:new_lightning(Amount),
    lightning_spend(IP, Port, Pubkey, Amount, Fee, Code, SS).
lightning_spend(IP, Port, Pubkey, Amount, Fee, Code, SS) ->
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    ESS = keys:encrypt([SS, Code, Amount], Pubkey),
    SSPK = channel_feeder:make_locked_payment(ServerID, Amount+Fee, Code),
    {ok, SSPK2} = talker:talk({locked_payment, SSPK, Amount, Fee, Code, keys:pubkey(), Pubkey, ESS}, IP, Port),
    true = testnet_sign:verify(keys:sign(SSPK2)),
    SPK = testnet_sign:data(SSPK),
    SPK = testnet_sign:data(SSPK2),
    channel_manager_update(ServerID, SSPK2, spk:new_ss(compiler_chalang:doit(<<>>), [])),
    ok.
channel_manager_update(ServerID, SSPK2, DefaultSS) ->
    %store SSPK2 in channel manager, it is their most recent signature.
    {ok, CD} = channel_manager:read(ServerID),
    SPK = testnet_sign:data(SSPK2),
    NewCD = CD#cd{me = SPK, them = SSPK2, ssme = [DefaultSS|CD#cd.ssme], ssthem = [DefaultSS|CD#cd.ssthem]},
    channel_manager:write(ServerID, NewCD),
    ok.
channel_balance() ->
    channel_balance({127,0,0,1}, constants:server_port()).
channel_balance(Ip, Port) ->
    {Balance, _} = integer_channel_balance(Ip, Port),
    Balance.
channel_balance2(Ip, Port) ->
    {_, Bal} = integer_channel_balance(Ip, Port),
    Bal.
integer_channel_balance(Ip, Port) ->
    {ok, Other} = talker:talk({pubkey}, Ip, Port),
    {ok, CD} = channel_manager:read(Other),
    SSPK = CD#cd.them,
    SPK = testnet_sign:data(SSPK),
    SS = CD#cd.ssthem,
    TP = tx_pool:get(),
    NewHeight = TP#tx_pool.height,
    Amount = SPK#spk.amount,
    BetAmounts = sum_bets(SPK#spk.bets),
    CID = SPK#spk.cid,
    Channel = trees:dict_tree_get(channels, CID),
    {channels:bal1(Channel)+Amount, channels:bal2(Channel)-Amount-BetAmounts}.
sum_bets([]) -> 0;
sum_bets([B|T]) ->
    B#bet.amount + sum_bets(T).
pretty_display(I) ->
    {ok, TokenDecimals} = application:get_env(ae_core, token_decimals),
    F = I / TokenDecimals,
    [Formatted] = io_lib:format("~.8f", [F]),
    Formatted.
channel_team_close(CID, Amount) ->
    Cost = trees:dict_tree_get(governance, ctc),
    channel_team_close(CID, Amount, ?Fee+Cost).
channel_team_close(CID, Amount, Fee) ->
    Tx = channel_team_close_tx:make_dict(CID, Amount, Fee),
    keys:sign(Tx).
channel_timeout() ->
    channel_timeout(constants:server_ip(), constants:server_port()).
channel_timeout(Ip, Port) ->
    {ok, Other} = talker:talk({pubkey}, Ip, Port),
    {ok, Fee} = application:get_env(ae_core, tx_fee),
    Trees = (tx_pool:get())#tx_pool.block_trees,
    Dict = (tx_pool:get())#tx_pool.dict,
    {ok, CD} = channel_manager:read(Other),
    CID = CD#cd.cid,
    {Tx, _} = channel_timeout_tx:make_dict(keys:pubkey(), Trees, CID, [], Fee, Dict),
    case keys:sign(Tx) of
        {error, locked} ->
            io:fwrite("your password is locked");
        Stx ->
            tx_pool_feeder:absorb(Stx)
    end.
channel_slash(_CID, Fee, SPK, SS) ->
    tx_maker0(channel_slash_tx:make_dict(keys:pubkey(), Fee, SPK, SS)).
new_question_oracle(Start, Question)->
    ID = find_id2(),
    new_question_oracle(Start, Question, ID),
    ID.

new_question_oracle(Start, Question, ID)->
    Cost = trees:dict_tree_get(governance, oracle_new),
    tx_maker0(oracle_new_tx:make_dict(keys:pubkey(), ?Fee+Cost, Question, Start, ID, 0, 0)).
new_governance_oracle(Start, GovName, GovAmount, DiffOracleID) ->
    GovNumber = governance:name2number(GovName),
    ID = find_id2(),
    Recent = trees:dict_tree_get(oracles, DiffOracleID),
    Cost = trees:dict_tree_get(governance, oracle_new),
    Tx = oracle_new_tx:make_dict(keys:pubkey(), ?Fee + Cost, <<>>, Start, ID, GovNumber, GovAmount),
    tx_maker0(Tx),
    ID.
oracle_bet(OID, Type, Amount) ->
    Cost = trees:dict_tree_get(governance, oracle_bet),
    oracle_bet(?Fee+Cost, OID, Type, Amount).
oracle_bet(Fee, OID, Type, Amount) ->
    tx_maker0(oracle_bet_tx:make_dict(keys:pubkey(), Fee, OID, Type, Amount)).
oracle_close(OID) ->
    Trees = (tx_pool:get())#tx_pool.block_trees,
    Dict = (tx_pool:get())#tx_pool.dict,
    Cost = trees:dict_tree_get(governance, oracle_close, Dict, Trees),
    oracle_close(?Fee+Cost, OID).
oracle_close(Fee, OID) ->
    tx_maker0(oracle_close_tx:make_dict(keys:pubkey(), Fee, OID)).
oracle_winnings(OID) ->
    Cost = trees:dict_tree_get(governance, oracle_winnings),
    oracle_winnings(?Fee+Cost, OID).
oracle_winnings(Fee, OID) ->
    tx_maker0(oracle_winnings_tx:make_dict(keys:pubkey(), Fee, OID)).
oracle_unmatched(OracleID) ->
    Cost = trees:dict_tree_get(governance, unmatched),
    oracle_unmatched(?Fee+Cost, OracleID).
oracle_unmatched(Fee, OracleID) ->
    tx_maker0(oracle_unmatched_tx:make_dict(keys:pubkey(), Fee, OracleID)).
account(Pubkey) when size(Pubkey) == 65 ->
    trees:dict_tree_get(accounts, Pubkey);
account(Pubkey) when ((size(Pubkey) > 85) and (size(Pubkey) < 90)) ->
    account(base64:decode(Pubkey)).
account() -> account(keys:pubkey()).
integer_balance() -> 
    A = account(),
    case A of
        empty -> 0;
        A -> A#acc.balance
    end.
balance() -> integer_balance().
mempool() -> lists:reverse((tx_pool:get())#tx_pool.txs).
halt() -> off().
off() ->
    testnet_sup:stop(),
    ok = application:stop(ae_core),
    ok = application:stop(ae_http).
mine_block() ->
    block:mine(1, 100000).
mine_block(0, Times) -> ok;
mine_block(Periods, Times) ->
    PB = block:top(),
    Top = block:block_to_header(PB),
    Txs = lists:reverse((tx_pool:get())#tx_pool.txs),
    Block = block:make(Top, Txs, PB#block.trees, keys:pubkey()),
    block:mine(Block, Times),
    timer:sleep(100),
    mine_block(Periods-1, Times).
channel_close() ->
    channel_close(?IP, ?Port).
channel_close(IP, Port) ->
    Cost = trees:dict_tree_get(governance, ctc),
    channel_close(IP, Port, ?Fee+Cost).
channel_close(IP, Port, Fee) ->
    {ok, PeerId} = talker:talk({pubkey}, IP, Port),
    {ok, CD} = channel_manager:read(PeerId),
    SPK = testnet_sign:data(CD#cd.them),
    Dict = (tx_pool:get())#tx_pool.dict,
    Height = (block:get_by_hash(headers:top()))#block.height,
    SS = CD#cd.ssthem,
    SS = [],
    {Amount, _Nonce, _Delay} = spk:dict_run(fast, SS, SPK, Height, 0, Dict),
    CID = SPK#spk.cid,
    Tx = channel_team_close_tx:make_dict(CID, Amount, Fee),
    STx = keys:sign(Tx),
    {ok, SSTx} = talker:talk({channel_close, CID, keys:pubkey(), SS, STx}, IP, Port),
    tx_pool_feeder:absorb(SSTx),
    0.
channel_solo_close() -> channel_solo_close({127,0,0,1}, 3010).
channel_solo_close(IP, Port) ->
    {ok, Other} = talker:talk({pubkey}, IP, Port),
    channel_solo_close(Other).
channel_solo_close(Other) ->
    Fee = free_constants:tx_fee(),
    {ok, CD} = channel_manager:read(Other),
    SSPK = CD#cd.them,
    SS = CD#cd.ssthem,
    Tx = channel_solo_close:make_dict(keys:pubkey(), Fee, keys:sign(SSPK), SS),
    STx = keys:sign(Tx),
    tx_pool_feeder:absorb(STx),
    ok.
channel_solo_close(_CID, Fee, SPK, ScriptSig) ->
    tx_maker0(channel_solo_close:make_dict(keys:pubkey(), Fee, SPK, ScriptSig)).
add_peer(IP, Port) ->
    peers:add({IP, Port}),
    0.
sync() -> sync(?IP, ?Port).
sync(IP, Port) -> sync:start([{IP, Port}]).
keypair() -> keys:keypair().
pubkey() -> base64:encode(keys:pubkey()).
new_pubkey(Password) -> keys:new(Password).
new_keypair() -> testnet_sign:new_key().
test() -> {test_response}.
channel_keys() -> channel_manager:keys().
keys_unlock(Password) ->
    keys:unlock(Password),
    0.
keys_new(Password) ->
    keys:new(Password),
    0.
market_match(OID) ->
    order_book:match_all([OID]),
    {ok, ok}.
settle_bets() ->
    channel_feeder:bets_unlock(channel_manager:keys()),
    {ok, ok}.
new_market(OID, Expires, Period) -> 
    %for now lets use the oracle id as the market id. this wont work for combinatorial markets.
    order_book:new_market(OID, Expires, Period).
    %set up an order book.
    %turn on the api for betting.
trade(Price, Type, Amount, OID, Height) ->
    trade(Price, Type, Amount, OID, Height, ?IP, ?Port).
trade(Price, Type, Amount, OID, Height, IP, Port) ->
    trade(Price, Type, Amount, OID, Height, ?Fee*2, IP, Port).
trade(Price, Type, A, OID, Height, Fee, IP, Port) ->
    Amount = A,
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    {ok, {Expires, 
	  Pubkey, %pubkey of market maker
	  Period}} = 
	talker:talk({market_data, OID}, IP, Port),
    BetLocation = constants:oracle_bet(),
    MarketID = OID,
    %type is true or false or one other thing...
    MyHeight = api:height(),
    true = Height =< MyHeight,
    SC = market:market_smart_contract(BetLocation, MarketID, Type, Expires, Price, Pubkey, Period, Amount, OID, Height),
    SSPK = channel_feeder:trade(Amount, Price, SC, ServerID, OID),
    Msg = {trade, keys:pubkey(), Price, Type, Amount, OID, SSPK, Fee},
    Msg = packer:unpack(packer:pack(Msg)),%sanity check
    {ok, SSPK2} =
	talker:talk(Msg, IP, Port),
    SPK = testnet_sign:data(SSPK),
    SPK = testnet_sign:data(SSPK2),
    channel_manager_update(ServerID, SSPK2, market:unmatched(OID)),
    ok.
cancel_trade(N) ->
    cancel_trade(N, ?IP, ?Port).
cancel_trade(N, IP, Port) ->
    %the nth bet in the channel (starting at 2) is an unmatched trade that we want to cancel.
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    channel_feeder:cancel_trade(N, ServerID, IP, Port),
    0.
combine_cancel_assets() ->
    combine_cancel_assets(?IP, ?Port).
combine_cancel_assets(IP, Port) ->
    {ok, ServerID} = talker:talk({pubkey}, IP, Port),
    channel_feeder:combine_cancel_assets(ServerID, IP, Port),
    0.
-define(mining, "data/mining_block.db").
work(Nonce, _) ->
    <<N:256>> = Nonce,
    Block = db:read(?mining),
    Block2 = Block#block{nonce = N},
    Header = block:block_to_header(Block2),
    headers:absorb([Header]),
    block_absorber:save(Block2),
    spawn(fun() -> sync:start() end),
    0.
mining_data() ->
    TP = tx_pool:get(),
    Height = TP#tx_pool.height,
    Txs = TP#tx_pool.txs,
    PB = block:get_by_height(Height),
    {ok, Top} = headers:read(block:hash(PB)),
    block_absorber:prune(),
    Block = block:make(Top, Txs, PB#block.trees, keys:pubkey()),
    spawn(fun() -> db:save(?mining, Block) end),
    NextDiff = headers:difficulty_should_be(Top),
    [hash:doit(block:hash(Block)), 
     crypto:strong_rand_bytes(32), 
     headers:difficulty_should_be(Top)].
    
    
