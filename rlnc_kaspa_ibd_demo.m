function rlnc_kaspa_ibd_demo()
% RLNC on a Kaspa-like blockDAG window for IBD
% - Field: GF(2) or GF(256) (AES poly 0x11D)
% - Sliding-window IBD with caching
% - Chunked symbols
% - Rateless RLNC (loss-aware & adaptive) + optional batched feedback
% - Honest time model (throughput + optional RTT per FEEDBACK ROUND)
% - CSV export (per-window + totals)
%
% Author: you + ChatGPT (2025-10-05)

rng(42);

%% ---------------- Experiment Parameters ----------------
% DAG model
L_levels        = 10;          % DAG depth (total)
W_minmax        = [3 5];       % width per level
parents_per_blk = [2 3];       % parents per block
tx_per_block_mu = 60;          % mean tx per block
p_tx_share      = 0.35;        % tx overlap probability
hdr_core_bytes  = 64;          % header core bytes
parent_hash_len = 32;          % parent hash bytes
tx_size_mean    = 500;         % mean tx bytes
tx_size_jitter  = 200;         % tx size jitter

factor_headers  = true;        % split header into core + parent-hash items
chunk_bytes     = 1024;         % chunk size (symbol length)
field_type      = 'GF256';     % 'GF2' or 'GF256'
overhead_mode   = 'seed';      % 'seed'(4B coeff seed) or 'packed'(K/8 bytes)
p_loss          = 0.20;        % per-packet loss probability
peers           = 5;           % parallel peers
max_packets     = 200000;      % safety cap

% RLNC scheduling (rateless + optional batched feedback)
epsilon_overcode   = 0.10;     % send +10% coded pkts beyond K (pre-loss)
repair_batch_size  = 512;      % coded pkts per feedback round (if used)
feedback_rounds    = 1;        % 0 = fully rateless; 1+ = # feedback rounds

% Sliding window
use_sliding_window = true;
win_levels         = 6;        % DAG levels per window
win_step_levels    = 3;        % advance per step (overlap allowed)

% Time model (per-peer)
peer_bandwidth_mbps  = 20;     % per-peer usable app-layer throughput
rtt_ms               = 60;     % RTT per FEEDBACK ROUND (not per packet)
seed_overhead_bytes  = 4;      % when overhead_mode='seed'
header_overhead_bytes= 2;      % toy per-packet headers (nonce/flags)

% CSV output
write_csv          = true;
csv_basename       = 'rlnc_ibd_results'; % file will be timestamped

%% ---------------- Build a global DAG -------------------
[blocks, ~, ~, itemMap] = build_dag_window( ...
    L_levels, W_minmax, parents_per_blk, p_tx_share, tx_per_block_mu, ...
    hdr_core_bytes, parent_hash_len, tx_size_mean, tx_size_jitter, factor_headers);

fprintf('\\n=== Kaspa-like DAG ===\\n');
fprintf('Levels: %d | Blocks: %d | Avg parents: %.2f | Avg tx: %.2f\\n', ...
    L_levels, numel(blocks), ...
    mean(arrayfun(@(b) numel(b.parents), blocks)), ...
    mean(arrayfun(@(b) numel(b.txIDs), blocks)));

%% ---------------- Either single-shot or sliding windows ---------------
metrics_rows = [];  % we'll collect structs then write CSV
if ~use_sliding_window
    [bytesA, bytesB, bytesC, timeA, timeB, timeC, recovered_now, row] = ...
        run_window(1, L_levels, blocks, itemMap, factor_headers, chunk_bytes, ...
                   field_type, overhead_mode, p_loss, peers, max_packets, ...
                   peer_bandwidth_mbps, rtt_ms, seed_overhead_bytes, header_overhead_bytes, ...
                   epsilon_overcode, repair_batch_size, feedback_rounds, []);
    metrics_rows = row; %#ok<NASGU>
    totals = row; % single row = totals
else
    total_bytes_blk_full = 0;
    total_bytes_unique   = 0;
    total_bytes_rlnc     = 0;
    total_time_blk_full  = 0;
    total_time_unique    = 0;
    total_time_rlnc      = 0;

    recovered_cache = containers.Map('KeyType','char','ValueType','logical'); % raw item cache

    fprintf('\\n=== Sliding-window IBD ===\\n');
    win_starts = 1:win_step_levels:(L_levels - win_levels + 1);
    metrics_rows = repmat(empty_row(), 0, 1);
    for i = 1:numel(win_starts)
        L0 = win_starts(i);
        L1 = L0 + win_levels - 1;

        fprintf('\\n--- Window %d/%d: levels [%d..%d] ---\\n', i, numel(win_starts), L0, L1);

        [bytesA, bytesB, bytesC, timeA, timeB, timeC, recovered_now, row] = ...
            run_window(L0, L1, blocks, itemMap, factor_headers, chunk_bytes, ...
                       field_type, overhead_mode, p_loss, peers, max_packets, ...
                       peer_bandwidth_mbps, rtt_ms, seed_overhead_bytes, header_overhead_bytes, ...
                       epsilon_overcode, repair_batch_size, feedback_rounds, ...
                       recovered_cache);

        metrics_rows(end+1) = row; %#ok<AGROW>

        % accumulate
        total_bytes_blk_full = total_bytes_blk_full + bytesA;
        total_bytes_unique   = total_bytes_unique   + bytesB;
        total_bytes_rlnc     = total_bytes_rlnc     + bytesC;
        total_time_blk_full  = total_time_blk_full  + timeA;
        total_time_unique    = total_time_unique    + timeB;
        total_time_rlnc      = total_time_rlnc      + timeC;

        % update cache
        for k = 1:numel(recovered_now)
            recovered_cache(recovered_now{k}) = true;
        end
    end

    fprintf('\\n=== Totals over all windows ===\\n');
    fprintf('Bytes  blk-full: %g | unique: %g | RLNC: %g\\n', total_bytes_blk_full, total_bytes_unique, total_bytes_rlnc);
    fprintf('Time s blk-full: %.3f | unique: %.3f | RLNC: %.3f\\n', total_time_blk_full, total_time_unique, total_time_rlnc);

    fprintf('Savings RLNC vs blk-full (bytes): %.1f%% | (time): %.1f%%\\n', ...
        100*(1 - total_bytes_rlnc/total_bytes_blk_full), ...
        100*(1 - total_time_rlnc /total_time_blk_full));
    fprintf('Savings RLNC vs unique   (bytes): %.1f%% | (time): %.1f%%\\n', ...
        100*(1 - total_bytes_rlnc/total_bytes_unique), ...
        100*(1 - total_time_rlnc /total_time_unique));

    % build totals row for CSV
    totals = empty_row();
    totals.window = "TOTALS";
    totals.level_start = min([metrics_rows.level_start]);
    totals.level_end   = max([metrics_rows.level_end]);
    totals.K_chunks    = sum([metrics_rows.K_chunks]);
    totals.sys_pkts    = sum([metrics_rows.sys_pkts]);
    totals.repair_pkts = sum([metrics_rows.repair_pkts]);
    totals.bytes_blk_full = total_bytes_blk_full;
    totals.bytes_unique   = total_bytes_unique;
    totals.bytes_rlnc     = total_bytes_rlnc;
    totals.time_blk_full  = total_time_blk_full;
    totals.time_unique    = total_time_unique;
    totals.time_rlnc      = total_time_rlnc;
    totals.sav_bytes_vs_blk  = 100*(1 - total_bytes_rlnc/total_bytes_blk_full);
    totals.sav_time_vs_blk   = 100*(1 - total_time_rlnc /total_time_blk_full);
    totals.sav_bytes_vs_uniq = 100*(1 - total_bytes_rlnc/total_bytes_unique);
    totals.sav_time_vs_uniq  = 100*(1 - total_time_rlnc /total_time_unique);
end

%% ---------------- Write CSV (optional) ----------------
if write_csv
    T = struct2table([metrics_rows, totals]); %#ok<NASGU>
    timestamp = datestr(now, 'yyyymmdd_HHMMSS');
    fname = sprintf('%s_%s.csv', csv_basename, timestamp);
    writetable(struct2table(metrics_rows), fname);          % per-window rows
    writetable(struct2table(totals), ['TOTALS_' fname]);    % totals row
    fprintf('\\nCSV written:\\n  %s\\n  %s\\n', fname, ['TOTALS_' fname]);
end
end

%% ============================ One-window runner ========================
function [bytesA, bytesB, bytesC, timeA, timeB, timeC, recovered_now_keys, row] = run_window( ...
    L0, L1, blocks, itemMap, factor_headers, chunk_bytes, ...
    field_type, overhead_mode, p_loss, peers, max_packets, ...
    peer_bw_mbps, rtt_ms, seed_overhead_bytes, header_overhead_bytes, ...
    epsilon_overcode, repair_batch_size, feedback_rounds, recovered_cache)

if nargin < 20, recovered_cache = []; end
have_cache = isa(recovered_cache,'containers.Map');

% Pick blocks in level [L0..L1]
blk_sel = blocks([blocks.level] >= L0 & [blocks.level] <= L1);

% Build the generation for this window (raw items)
[gen_raw, ~] = build_generation(blk_sel, itemMap, factor_headers);

% Apply cache: remove items we already have
if have_cache && ~isempty(recovered_cache)
    keep = true(1, numel(gen_raw.items));
    for i = 1:numel(gen_raw.items)
        if recovered_cache.isKey(key(gen_raw.items(i).id))
            keep(i) = false;
        end
    end
    gen_raw.items = gen_raw.items(keep);
end

% Early exit if nothing to fetch
if isempty(gen_raw.items)
    bytesA=0; bytesB=0; bytesC=0;
    timeA=0; timeB=0; timeC=0;
    recovered_now_keys = {};
    row = empty_row(); row.window=sprintf('[%d..%d]',L0,L1);
    fprintf('Nothing new in this window; everything was already cached.\\n');
    return;
end

% Chunk them
[gen, chunk_map] = chunk_generation(gen_raw, chunk_bytes);
K = numel(gen.items); Lbytes = chunk_bytes;

% Baselines (raw bytes)
[bytes_blk_full_raw, bytes_unique_pull_raw] = baseline_bytes(blk_sel, itemMap, factor_headers);
% Remove cached raw bytes from baselines (best-case dedup awareness)
if have_cache && ~isempty(recovered_cache)
    cached_ids = keys(recovered_cache);
    cached_set = string(cached_ids);
    bytes_unique_pull_raw = bytes_unique_pull_raw - cached_bytes_of_set(blk_sel, itemMap, factor_headers, cached_set);
    bytes_blk_full_raw    = bytes_blk_full_raw  - cached_bytes_of_set(blk_sel, itemMap, factor_headers, cached_set);
    bytes_blk_full_raw = max(bytes_blk_full_raw, 0);
    bytes_unique_pull_raw = max(bytes_unique_pull_raw, 0);
end

% Convert to chunks and loss-adjusted bytes for time model
chunks_blk_full   = ceil(bytes_blk_full_raw / Lbytes);
chunks_unique     = ceil(bytes_unique_pull_raw / Lbytes);
loss_mult         = 1/(1 - p_loss);

% Per packet overhead used in time model
coeff_overhead = strcmp(overhead_mode,'seed') * seed_overhead_bytes + ...
                 strcmp(overhead_mode,'packed') * ceil(K/8);
pkt_bytes_rlnc     = Lbytes + header_overhead_bytes + coeff_overhead; %#ok<NASGU>

bytesA = chunks_blk_full  * Lbytes * loss_mult;
bytesB = chunks_unique    * Lbytes * loss_mult;

% Baselines time: peers in parallel, link-saturated streaming
peer_bw_Bps = peer_bw_mbps * 1e6 / 8;
timeA = (bytesA / (peers * peer_bw_Bps));
timeB = (bytesB / (peers * peer_bw_Bps));

% ---------------- RLNC download & decode ----------------
% Build chunk matrix
Xtrue = zeros(K, Lbytes, 'uint8');
for i = 1:K
    buf = gen.items(i).bytes;
    Xtrue(i,1:numel(buf)) = buf;
end
ops = get_field_ops(field_type);

% Rateless target (***loss-aware***): aim to RECEIVE ≈ K*(1+ε)
% Therefore EMIT ≈ K*(1+ε)/(1-p_loss)
target_pkts_emit = ceil(K * (1 + epsilon_overcode) / max(1e-9, (1 - p_loss)));

[recvCount, bytes_rlnc, rank_hit, R, Y, sys_pkts, repair_pkts] = rlnc_download( ...
    K, Lbytes, peers, p_loss, overhead_mode, max_packets, Xtrue, ...
    ops, target_pkts_emit, repair_batch_size, feedback_rounds);

if ~rank_hit
    % As a safety valve, keep sending until full-rank or we hit the cap.
    warning('RLNC not full rank after target; sending extra until full-rank or cap.');
    [recvCount2, bytes_rlnc2, rank_hit2, R, Y, sys_pkts2, repair_pkts2] = rlnc_download( ...
        K, Lbytes, peers, p_loss, overhead_mode, max_packets - recvCount, Xtrue, ...
        ops, inf, repair_batch_size, 0); %#ok<NASGU,ASGLU>
    recvCount  = recvCount  + recvCount2;
    bytes_rlnc = bytes_rlnc + bytes_rlnc2;
    repair_pkts= repair_pkts+ repair_pkts2;
    rank_hit = rank_hit2;
end
if ~rank_hit, error('RLNC: full rank not achieved within limit.'); end

% Decode & verify
X = rlnc_decode(K, Lbytes, R, Y, ops);
recoveredChunks = recover_items_from_solution(gen, X);
recoveredItems  = unchunk_to_items(recoveredChunks, chunk_map);
ok = verify_block_reconstruction(blk_sel, recoveredItems, factor_headers);
if ~ok, error('Block reconstruction failed in window.'); end

bytesC = bytes_rlnc;

% ======= TIME MODEL (pipelined streams + batched feedback) =======
time_data = (bytesC) / (peers * peer_bw_Bps);
if feedback_rounds <= 0
    time_feedback = 0;
else
    % approximate number of feedback rounds actually used:
    % extra beyond K divided by batch per all peers
    extra_recv = max(recvCount - K, 0);
    rounds_used = max(1, ceil( extra_recv / max(1, (peers * repair_batch_size)) ));
    time_feedback = rounds_used * (rtt_ms / 1000);
end
timeC = time_data + time_feedback;

fprintf('K=%d | coded sent=%d | bytes RLNC=%g | time=%.3fs\\n', ...
    K, recvCount, bytesC, timeC);
fprintf('Savings RLNC vs blk-full   bytes: %.1f%%  time: %.1f%%\\n', ...
    100*(1 - bytesC/bytesA), 100*(1 - timeC/timeA));
fprintf('Savings RLNC vs unique     bytes: %.1f%%  time: %.1f%%\\n', ...
    100*(1 - bytesC/bytesB), 100*(1 - timeC/timeB));

% Return the set of newly recovered raw ids (so outer loop can cache them)
raw_ids = fieldnames(recoveredItems);
recovered_now_keys = raw_ids.';

% Build one CSV row
row = empty_row();
row.window         = sprintf('[%d..%d]',L0,L1);
row.level_start    = L0;
row.level_end      = L1;
row.K_chunks       = K;
row.sys_pkts       = sys_pkts;
row.repair_pkts    = repair_pkts;
row.bytes_blk_full = bytesA;
row.bytes_unique   = bytesB;
row.bytes_rlnc     = bytesC;
row.time_blk_full  = timeA;
row.time_unique    = timeB;
row.time_rlnc      = timeC;
row.sav_bytes_vs_blk  = 100*(1 - bytesC/bytesA);
row.sav_time_vs_blk   = 100*(1 - timeC/timeA);
row.sav_bytes_vs_uniq = 100*(1 - bytesC/bytesB);
row.sav_time_vs_uniq  = 100*(1 - timeC/timeB);
end

function r = empty_row()
r = struct('window',"", 'level_start',0,'level_end',0,'K_chunks',0, ...
    'sys_pkts',0,'repair_pkts',0, ...
    'bytes_blk_full',0,'bytes_unique',0,'bytes_rlnc',0, ...
    'time_blk_full',0,'time_unique',0,'time_rlnc',0, ...
    'sav_bytes_vs_blk',0,'sav_time_vs_blk',0, ...
    'sav_bytes_vs_uniq',0,'sav_time_vs_uniq',0);
end

function bytes = cached_bytes_of_set(blk_sel, itemMap, factor_headers, cached_set)
% Count how many raw bytes inside blk_sel are already present in cache
allIDs = [];
for i=1:numel(blk_sel)
    b=blk_sel(i);
    allIDs(end+1)=b.hdrCoreID; %#ok<AGROW>
    if factor_headers, allIDs=[allIDs,b.parentHashIDs]; end %#ok<AGROW>
    allIDs=[allIDs,b.txIDs]; %#ok<AGROW>
end
allIDs = unique(allIDs);
bytes = 0;
for id = allIDs
    kk = key(id);
    if any(strcmp(cached_set, kk))
        bytes = bytes + itemMap(kk).len;
    end
end
end

%% ======================= DAG building & generation =====================
function [blocks, parentItems, txItems, itemMap] = build_dag_window( ...
    L, Wminmax, pper, pshare, tx_mu, hdr_core_bytes, ph_len, tx_mean, tx_jit, factor_headers)

blocks = struct('id',{},'level',{},'parents',{},'hdrCoreID',{},'parentHashIDs',{},'txIDs',{});
parentItems = struct('id',{},'bytes',{},'len',{});
txItems     = struct('id',{},'bytes',{},'len',{});

nextHdrCoreID=1e6; nextParentID=2e6; nextTxID=3e6; recentParentIDs = [];

for lev = 1:L
    width = randi(Wminmax);
    prevBlocks = [blocks([blocks.level] < lev).id];
    for w = 1:width
        b.id = lev*1000 + w; b.level = lev;
        np = randi(pper);
        b.parents = [];
        if ~isempty(prevBlocks), b.parents = randsample(prevBlocks, min(np, numel(prevBlocks))); end

        % header-core unique
        hdrCore.id    = nextHdrCoreID; nextHdrCoreID = nextHdrCoreID + 1;
        hdrCore.bytes = uint8(randi([0 255],1,hdr_core_bytes)); hdrCore.len = hdr_core_bytes;

        % parent-hashes, prefer reuse
        phIDs = [];
        for i = 1:numel(b.parents)
            if ~isempty(recentParentIDs) && rand < 0.7
                phID = recentParentIDs(randi(numel(recentParentIDs)));
            else
                ph.id    = nextParentID; nextParentID = nextParentID + 1;
                ph.bytes = uint8(randi([0 255],1,ph_len)); ph.len   = ph_len;
                parentItems(end+1)=ph; %#ok<AGROW>
                phID=ph.id; recentParentIDs=[recentParentIDs,phID];
                if numel(recentParentIDs)>200, recentParentIDs=recentParentIDs(end-200+1:end); end
            end
            phIDs(end+1)=phID; %#ok<AGROW>
        end

        % transactions with overlap
        nTx=max(0,round(tx_mu+randn*sqrt(tx_mu)));
        tIDs=zeros(1,nTx);
        for t=1:nTx
            if rand<pshare && ~isempty(txItems)
                tIDs(t)=txItems(randi(numel(txItems))).id;
            else
                tlen=max(80,round(tx_mean+(2*rand-1)*tx_jit));
                tx.id=nextTxID; nextTxID=nextTxID+1;
                tx.bytes=uint8(randi([0 255],1,tlen)); tx.len=tlen;
                txItems(end+1)=tx; %#ok<AGROW>
                tIDs(t)=tx.id;
            end
        end

        b.hdrCoreID=hdrCore.id; b.parentHashIDs=phIDs; b.txIDs=tIDs;
        blocks(end+1)=b; %#ok<AGROW>
        hdrCoreItems.(sprintf('id_%d',hdrCore.id))=hdrCore; %#ok<NASGU>
    end
end

% Build item map
itemMap = containers.Map('KeyType','char','ValueType','any');
for i=1:numel(blocks)
    k=key(blocks(i).hdrCoreID);
    itemMap(k)=struct('id',blocks(i).hdrCoreID,'type','hdr-core', ...
        'bytes',uint8(randi([0 255],1,hdr_core_bytes)),'len',hdr_core_bytes);
end
for i=1:numel(parentItems)
    k=key(parentItems(i).id);
    itemMap(k)=struct('id',parentItems(i).id,'type','parent-hash', ...
        'bytes',parentItems(i).bytes,'len',parentItems(i).len);
end
for i=1:numel(txItems)
    k=key(txItems(i).id);
    itemMap(k)=struct('id',txItems(i).id,'type','tx', ...
        'bytes',txItems(i).bytes,'len',txItems(i).len);
end

% Collapse headers if desired
if ~factor_headers
    for i=1:numel(blocks)
        payload=itemMap(key(blocks(i).hdrCoreID)).bytes;
        for ph=blocks(i).parentHashIDs
            payload=[payload,itemMap(key(ph)).bytes]; %#ok<AGROW>
        end
        hid=blocks(i).hdrCoreID;
        itemMap(key(hid))=struct('id',hid,'type','hdr-core','bytes',payload,'len',numel(payload));
        blocks(i).parentHashIDs=[];
    end
end
end

function [gen,needMask]=build_generation(blocks,itemMap,factor_headers)
needIDs=[];
for i=1:numel(blocks)
    b=blocks(i);
    needIDs(end+1)=b.hdrCoreID; %#ok<AGROW>
    if factor_headers, needIDs=[needIDs,b.parentHashIDs]; end %#ok<AGROW>
    needIDs=[needIDs,b.txIDs]; %#ok<AGROW>
end
needIDs=unique(needIDs);
items=repmat(struct('id',0,'type','','bytes',[],'len',0),1,numel(needIDs));
for j=1:numel(needIDs), items(j)=itemMap(key(needIDs(j))); end
gen.items=items; needMask=true(1,numel(items));
end

%% ===================== Chunking & Unchunking ===========================
function [gen_out, chunk_map] = chunk_generation(gen_in, chunk_bytes)
items_in = gen_in.items; chunks = []; chunk_map = struct();
for i=1:numel(items_in)
    it = items_in(i); B = it.bytes(:).'; n = numel(B);
    nChunks = ceil(n / chunk_bytes);
    chunk_ids = strings(1,nChunks);
    for c=1:nChunks
        s=(c-1)*chunk_bytes+1; e=min(c*chunk_bytes,n);
        ch.bytes=B(s:e); ch.len=numel(ch.bytes);
        ch.type=it.type; ch.raw_id=it.id; ch.idx=c;
        ch.id=double(it.id)*1e3 + c; chunks=[chunks,ch]; %#ok<AGROW>
        chunk_ids(c)=string(chunk_key(ch.raw_id, ch.idx));
    end
    chunk_map.(key(it.id)) = chunk_ids;
end
gen_out.items = chunks;
end

function recovered_raw = unchunk_to_items(recoveredChunks, chunk_map)
raw_ids = fieldnames(chunk_map);
recovered_raw = containers.Map('KeyType','char','ValueType','any');
for r = 1:numel(raw_ids)
    rid_key = raw_ids[rid_key = raw_ids{r}];
    ch_keys = chunk_map.(rid_key);
    buf = uint8([]);
    for c = 1:numel(ch_keys)
        ch = recoveredChunks(ch_keys(c)); buf = [buf, ch.bytes]; %#ok<AGROW>
    end
    rid_num = sscanf(rid_key, 'id_%d');
    recovered_raw(rid_key) = struct('id', rid_num, 'type', 'unknown', ...
        'bytes', buf, 'len', numel(buf));
end
end

%% ========================= Baselines (raw bytes) =======================
function [bytes_blk_full, bytes_unique_pull] = baseline_bytes(blocks,itemMap,factor_headers)
bytes_blk_full=0;
for i=1:numel(blocks)
    b=blocks(i);
    if factor_headers
        hdrCore=itemMap(key(b.hdrCoreID)).len;
        phBytes=sum(arrayfun(@(x)itemMap(key(x)).len,b.parentHashIDs));
        hdrBytes=hdrCore+phBytes;
    else
        hdrBytes=itemMap(key(b.hdrCoreID)).len;
    end
    txBytes=sum(arrayfun(@(x)itemMap(key(x)).len,b.txIDs));
    bytes_blk_full=bytes_blk_full+hdrBytes+txBytes;
end
allIDs=[];
for i=1:numel(blocks)
    b=blocks(i);
    allIDs(end+1)=b.hdrCoreID; %#ok<AGROW>
    if factor_headers, allIDs=[allIDs,b.parentHashIDs]; end %#ok<AGROW>
    allIDs=[allIDs,b.txIDs]; %#ok<AGROW>
end
allIDs=unique(allIDs);
bytes_unique_pull=0;
for id=allIDs, bytes_unique_pull=bytes_unique_pull+itemMap(key(id)).len; end
end

%% =================== Field selection & ops ============================
function ops = get_field_ops(field_type)
switch upper(field_type)
    case 'GF2'
        ops.type = 'GF2';
        ops.zero = @(x) zeros(size(x),'uint8');
        ops.xor  = @(a,b) bitxor(a,b);
        ops.elim = @(A,B) gf2_eliminate(A,B); % not used directly here
    case 'GF256'
        [logt, expt] = gf256_tables(); % AES polynomial 0x11D
        ops.type='GF256';
        ops.logt=logt; ops.expt=expt;
        ops.zero = @(x) zeros(size(x),'uint8');
        ops.xor  = @(a,b) bitxor(a,b);
        ops.elim = @(A,B) gf256_eliminate(A,B,logt,expt);
    otherwise
        error('Unknown field type');
end
end

%% ========================= RLNC download (rateless) ===================
function [recvCount,totalBytes,rank_hit,R,Y, sys_pkts, repair_pkts] = rlnc_download( ...
    K,Lbytes,peers,p_loss,overhead_mode,max_packets,Xtrue, ...
    ops, target_pkts_emit, repair_batch_size, feedback_rounds)

R = false(0,K); Y = zeros(0,Lbytes,'uint8');  % GF(2) bookkeeping
C = [];                                        % GF(256) coeffs, if used
curRank=0; rank_hit=false;
recvCount=0; totalBytes=0; peer=1;
sys_pkts=0; repair_pkts=0;

if strcmp(overhead_mode,'packed'), coeffBytes=ceil(K/8); else, coeffBytes=4; end

% Helper: emit one coded packet (counts only if RECEIVED)
    function emit_one()
        % Generate coefficients & payload
        if strcmp(overhead_mode,'packed')
            coeff_mask = rand(1,K)>0.5;
            if strcmp(ops.type,'GF2')
                idx=find(coeff_mask);
                payload=zeros(1,Lbytes,'uint8');
                if ~isempty(idx)
                    payload = Xtrue(idx(1),:);
                    for k=2:numel(idx), payload=bitxor(payload,Xtrue(idx(k),:)); end
                end
                if rand < p_loss, peer=advance_peer(peer,peers); return; end
                R=[R; coeff_mask]; Y=[Y; payload];
                [R,Y,curRank]=gf2_row_reduce(R,Y);
            else
                coeff_row = uint8(coeff_mask); % 0/1 — OK but not ideal
                payload = zeros(1,Lbytes,'uint8');
                for j=1:K
                    a = coeff_row(j);
                    if a~=0
                        payload = bitxor(payload, Xtrue(j,:)); % a==1 -> XOR
                    end
                end
                if rand < p_loss, peer=advance_peer(peer,peers); return; end
                C=[C; coeff_row]; Y=[Y; payload];
                [C,Y,curRank] = ops.elim(C,Y);
            end
        else
            % seed coefficients
            seed = randi([0 2^32-1],1,'uint32');
            coeff_mask = make_coeffs_seed_mask(seed,K);
            if strcmp(ops.type,'GF2')
                idx=find(coeff_mask);
                payload=zeros(1,Lbytes,'uint8');
                if ~isempty(idx)
                    payload = Xtrue(idx(1),:);
                    for k=2:numel(idx), payload=bitxor(payload,Xtrue(idx(k),:)); end
                end
                if rand < p_loss, peer=advance_peer(peer,peers); return; end
                R=[R; coeff_mask]; Y=[Y; payload];
                [R,Y,curRank]=gf2_row_reduce(R,Y);
            else
                coeff_row = make_coeffs_seed_gf256(seed,K);
                payload = zeros(1,Lbytes,'uint8');
                for j=1:K
                    a = coeff_row(j);
                    if a~=0
                        payload = gf256_axpy(payload, Xtrue(j,:), a, ops.logt, ops.expt);
                    end
                end
                if rand < p_loss, peer=advance_peer(peer,peers); return; end
                C=[C; coeff_row]; Y=[Y; payload];
                [C,Y,curRank] = ops.elim(C,Y);
            end
        end
        recvCount  = recvCount + 1;
        totalBytes = totalBytes + (Lbytes + coeffBytes);
        peer=advance_peer(peer,peers);
    end

% ---- Rateless initial burst: emit until we RECEIVE at least target_pkts_emit
while curRank < K && recvCount < min(target_pkts_emit, max_packets)
    emit_one();
end
repair_pkts = recvCount;  % all are coded (no systematic here)

% ---- Optional: a few feedback rounds with batched repairs
rounds_done = 0;
while curRank < K && rounds_done < feedback_rounds && recvCount < max_packets
    to_send = min(repair_batch_size * peers, max_packets - recvCount);
    for s = 1:to_send
        emit_one();
        if curRank >= K, break; end
    end
    rounds_done = rounds_done + 1;
end

% ---- If still not full rank and feedback_rounds==0, keep ratelessly sending
while curRank < K && recvCount < max_packets && feedback_rounds==0
    emit_one();
end

rank_hit = (curRank == K);
end

function p2 = advance_peer(p,peers)
p2 = p + 1; if p2>peers, p2=1; end
end

%% ========================= Decoding ============================
function X = rlnc_decode(K,Lbytes,R,Y,ops)
if strcmp(ops.type,'GF2')
    % Y already row-reduced alongside R; reorder to pivot order
    pivotRow = zeros(1,K);
    for col=1:K
        r=find(R(:,col),1,'first');
        if isempty(r), error('Not full rank; cannot decode.'); end
        pivotRow(col)=r;
    end
    [~,order]=sort(pivotRow);
    X = Y(order,:);
else
    % For GF256, ops.elim produced a row-echelon system; return first K rows
    X = Y(1:K,:);
end
end

%% ==================== GF(2) helpers ============================
function [R,Y,rank] = gf2_row_reduce(R,Y)
[m,n]=size(R); rank=0; row=1;
for col=1:n
    pivot=find(R(row:m,col),1,'first');
    if isempty(pivot),continue;end
    pivot=pivot+row-1;
    if pivot~=row
        tmp=R(row,:);R(row,:)=R(pivot,:);R(pivot,:)=tmp;
        tmp=Y(row,:);Y(row,:)=Y(pivot,:);Y(pivot,:)=tmp;
    end
    for r=[1:row-1,row+1:m]
        if R(r,col)
            R(r,:)=xor(R(r,:),R(row,:));
            Y(r,:)=bitxor(Y(r,:),Y(row,:));
        end
    end
    row=row+1; rank=rank+1;
    if row>m,break;end
end
nz=any(R,2); R=R(nz,:); Y=Y(nz,:);
end

function mask = make_coeffs_seed_mask(seed,K)
s = uint32(seed); mask = false(1,K);
for i=1:ceil(K/32)
    s = bitxor(s, bitshift(s,13));
    s = bitxor(s, bitshift(s,-17));
    s = bitxor(s, bitshift(s,5));
    idx = (i-1)*32 + (1:32); idx = idx(idx<=K);
    bits = bitget(s,1:32)==1; mask(idx)=bits(1:numel(idx));
end
end

%% ==================== GF(256) helpers ==========================
function [logt, expt] = gf256_tables()
% exp/log tables for GF(256) with primitive poly 0x11D (AES)
expt = uint8(zeros(1,512)); logt = uint8(zeros(1,256));
x = uint8(1);
for i=1:255
    expt(i) = x;
    logt(double(x)+1) = uint8(i-1);
    x = xtime(x); % multiply by 0x02
end
for i=256:512
    expt(i) = expt(i-255);
end
    function y=xtime(a)
        y = bitshift(a,1);
        if bitget(a,8)
            y = bitxor(y, uint8(0x1d)); % (0x11D & 0xFF)
        end
    end
end

function row = make_coeffs_seed_gf256(seed,K)
% PRNG to bytes in 1..255 (avoid 0 for better rank odds)
s = uint32(seed);
row = zeros(1,K,'uint8');
for i=1:K
    s = bitxor(s, bitshift(s,13));
    s = bitxor(s, bitshift(s,-17));
    s = bitxor(s, bitshift(s,5));
    b = bitand(s, uint32(255));
    if b==0, b=1; end
    row(i)=uint8(b);
end
end

function [C,Y,rank] = gf256_eliminate(C,Y,logt,expt)
% Gaussian elimination (row-echelon) over GF(256)
[m,n] = size(C); rank=0; row=1;
for col=1:n
    pivot = 0;
    for r=row:m
        if C(r,col) ~= 0, pivot = r; break; end
    end
    if pivot==0, continue; end
    if pivot~=row
        tmp=C(row,:); C[row,:]=C(pivot,:); C(pivot,:)=tmp;
        tmp=Y[row,:]; Y[row,:]=Y(pivot,:); Y(pivot,:)=tmp;
    end
    invp = gf256_inv(C(row,col),logt,expt);
    C(row,:) = gf256_scale_row(C(row,:), invp, logt, expt);
    Y(row,:) = gf256_scale_row(Y(row,:), invp, logt, expt);
    for r=[1:row-1, row+1:m]
        a = C(r,col);
        if a~=0
            C(r,:) = gf256_axpy(C(r,:), C(row,:), a, logt, expt);
            Y(r,:) = gf256_axpy(Y(r,:), Y(row,:), a, logt, expt); % typo fix below
        end
    end
    row=row+1; rank=rank+1;
    if row>m, break; end
end
% trim zero rows
nz = any(C,2); C = C(nz,:); Y = Y(nz,:);
end

function inva = gf256_inv(a,logt,expt)
if a==0, error('No inverse for 0'); end
ia = double(logt(double(a)+1))+1;
inva = expt(256 - ia + 1); % a^(255-1) = a^-1
end

function dst = gf256_scale_row(row,alpha,logt,expt)
if alpha==0, dst = uint8(zeros(size(row))); return; end
if alpha==1, dst = row; return; end
ia = double(logt(double(alpha)+1))+1;
dst = row;
nz = row~=0;
ilog = double(logt(double(row(nz))+1))+1;
dst(nz) = expt(ilog + ia - 1);
end

function dst = gf256_axpy(dst,src,alpha,logt,expt)
if alpha==0, return; end
if alpha==1
    dst = bitxor(dst,src); return;
end
nz = src~=0;
ilog = double(logt(double(src(nz))+1))+1;
ia = double(logt(double(alpha)+1))+1;
dst(nz) = bitxor(dst(nz), expt(ilog + ia - 1));
end

%% ===================== Recovery & Verification =========================
function rec_chunks = recover_items_from_solution(gen,X)
rec_chunks=containers.Map('KeyType','char','ValueType','any');
for i=1:numel(gen.items)
    it=gen.items(i);
    row=X(i,1:it.len);
    rec_chunks(chunk_key(it.raw_id,it.idx))=struct( ...
        'raw_id', it.raw_id, 'idx', it.idx, 'bytes', row, 'len', it.len);
end
end

function ok=verify_block_reconstruction(blocks,rec,factor_headers)
ok=true;
for i=1:numel(blocks)
    b=blocks(i);
    if ~rec.isKey(key(b.hdrCoreID)), ok=false; return; end
    if factor_headers
        for ph=b.parentHashIDs
            if ~rec.isKey(key(ph)), ok=false; return; end
        end
    end
    for t=b.txIDs
        if ~rec.isKey(key(t)), ok=false; return; end
    end
end
end

%% ========================= Small helpers ===============================
function k=key(id), k=sprintf('id_%d',id); end
function k=chunk_key(raw_id, idx), k=sprintf('chunk_%d_%d', raw_id, idx); end
