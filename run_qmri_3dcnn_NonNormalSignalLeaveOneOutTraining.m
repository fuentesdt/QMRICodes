%% run_qmri_3dcnn_Leave_One_Out
% 3D CNN (U-Net) for qMRI: predict PD, T1, T2, g1, g2, g3
% Physics-guided loss (no T2* in GRE)
% Auto CPU/GPU. T1 in (0,5000], T2 in (0,3000], PD in [0,150].

clear; clc; close all;
Num_patients = 11;   % this number can change with data availability
%% ===================== 0) CONFIG ==========================
for L = 1:Num_patients % looping over all the patients leaving one patient out during the training
config.rootDir     = pwd; % The folder in which this code is saved. Place this file in a master-folder that contains 
                          % all patients data within patient sub-folder
config.outDir      = fullfile(config.rootDir,['trained_models_P',num2str(L)]);  % Folder that saves the trained network. 
                                                                                % P1 means, Patient-1 is left out from training 
config.excelName   = ['acq_paramsP',num2str(L),'.xlsx']; % This is the excel file with 
                                                        % all patients acquisition parameters 
                                                        % except the patient left-out during the training

% Patient identifier column and the input file names for training. Make
% sure each patient sub-folder has below listed 7 files in it.
config.idCol       = "PatientID";
config.fileT1w     = "PREOP_T1_W_S.nii.gz";     % Acquired T1W Signal 
config.fileT2w     = "PREOP_AxT2_W_S.nii.gz";   % Acquired T2W Signal
config.fileFLAIR   = "PREOP_FLAIR_W_S.nii.gz";  % Acquired Flair Signal
config.filePDref   = "pdmap.nii.gz";            % Reference PD Map
config.fileT1ref   = "t1map.nii.gz";            % Reference T1 Map
config.fileT2ref   = "t2map.nii.gz";            % Reference T2 Map
config.fileMask    = "mask.nii.gz";             % Mask of Skull-stripped brain

% Training Network architechture definition
config.patchSize   = [64 64 64];   % [Z Y X]
config.patchStride = [32 32 32];
config.baseFilters = 32;
config.maxEpochs   = 200;
config.learnRate   = 2e-4;
config.batchSize   = 2;
config.weightDecay = 1e-4;

% Loss weights
config.wSignal     = [1 1 1];    % T1w, T2w, FLAIR
config.lamPD       = 1.0;        % parameter L1 (PD)
config.lamT1       = 1.0;        % parameter L1 (log T1)
config.lamT2       = 1.0;        % parameter L1 (log T2)

% Output ranges (HARD CAPS via scaled sigmoid)
config.PDmax       = 150;
config.T1max       = 5000;       % cap
config.T2max       = 3000;       % cap
config.g1max       = 500;
config.g2max       = 500;       % cap
config.g3max       = 500;       % cap

% Regularization (edge-aware TV & gain smoothness)
config.tvPD        = 1e-4;       % TV on PD
config.tvT1        = 1e-4;       % TV on log T1
config.tvT2        = 1e-4;       % TV on log T2
config.smoothG     = 5e-5;       % L2 smoothness on gains
config.kappaEdge   = 2.0;        % edge sensitivity
config.epsTV       = 1e-3;       % Charbonnier epsilon

% Saving
config.ckptEvery   = 20;         % save the network at every 20 epochs

if ~exist(config.outDir,'dir'); mkdir(config.outDir); end

%% ===================== 1) DEVICE SELECT ===================
useGPU = canUseGPU();
if useGPU
    g = gpuDevice(3); fprintf('[Device] Using GPU: %s\n', g.Name);
else
    fprintf('[Device] No GPU detected. Using CPU (multithread if available).\n');
    try, if isempty(gcp('nocreate')); parpool('threads'); end, catch, end
end

%% ===================== 2) READ EXCEL ======================
excelPath = fullfile(config.rootDir, config.excelName);
assert(isfile(excelPath), 'Excel file not found: %s', excelPath);
T = readtable(excelPath);
assert(any(strcmpi(T.Properties.VariableNames, config.idCol)), 'Missing ID column "%s".', config.idCol);

needCols = ["TRT1","TET1","FAT1_deg","TRT2","TET2","TRFLAIR","TEFLAIR","TIFLAIR"];
for c = needCols
    assert(any(strcmpi(T.Properties.VariableNames, c)), 'Excel missing column "%s".', c);
end

%% ===================== 3) DISCOVER PATIENTS ===============
patientIDs = string(T.(config.idCol));
patientIDs = patientIDs(~ismissing(patientIDs) & strlength(patientIDs)>0);

patients = struct('id',{},'paths',{},'acq',[]);
for L = 1:numel(patientIDs)
    pid = patientIDs(L);
    pdir = fullfile(config.rootDir, pid);
    if ~isfolder(pdir), warning('Missing folder: %s (skip)', pdir); continue; end
    paths.T1w   = fullfile(pdir, config.fileT1w);
    paths.T2w   = fullfile(pdir, config.fileT2w);
    paths.FLAIR = fullfile(pdir, config.fileFLAIR);
    paths.PDref = fullfile(pdir, config.filePDref);
    paths.T1ref = fullfile(pdir, config.fileT1ref);
    paths.T2ref = fullfile(pdir, config.fileT2ref);
    paths.mask  = fullfile(pdir, config.fileMask);

    miss = {};
    fn = fieldnames(paths);
    for f = 1:numel(fn), if ~isfile(paths.(fn{f})), miss{end+1} = fn{f}; end, end
    if ~isempty(miss), warning('%s missing: %s (skip)', pid, strjoin(miss,', ')); continue; end

    row = T(strcmp(string(T.(config.idCol)), pid), :);
    acq = [row.TRT1,row.TET1,row.FAT1_deg,row.TRT2,row.TET2,row.TRFLAIR,row.TEFLAIR,row.TIFLAIR];
    patients(end+1) = struct('id',pid,'paths',paths,'acq',acq); 
end
assert(~isempty(patients),'No valid patients found.');

%% ===================== 4) LOAD + PATCH ====================
fprintf('[Data] Loading volumes & building patches...\n');
allPatches = {};
for k = 1:numel(patients)
    P  = patients(k);
    S1 = readNii(P.paths.T1w);
    S2 = readNii(P.paths.T2w);
    S3 = readNii(P.paths.FLAIR);
    PD = readNii(P.paths.PDref);
    T1 = readNii(P.paths.T1ref);
    T2 = readNii(P.paths.T2ref);
    M  = logical(readNii(P.paths.mask));
    assert(isequal(size(S1),size(S2),size(S3),size(PD),size(T1),size(T2),size(M)), ...
        'Size mismatch for %s', P.id);

    % Build patches
    patches = extractPatches3D(S1,S2,S3,PD,T1,T2,M,config.patchSize,config.patchStride);

    % Attach acquisition vector (flip angle -> rad)
    for p = 1:numel(patches)
        patches{p}.acq = single([P.acq(1),P.acq(2),deg2rad(P.acq(3)), ...
            P.acq(4),P.acq(5),P.acq(6),P.acq(7),P.acq(8)]);
    end
    allPatches = [allPatches; patches(:)];
    fprintf('  %s -> %d patches\n', P.id, numel(patches));
end
numPatches = numel(allPatches);
fprintf('[Data] Total patches: %d\n', numPatches);

% Split (80/20)
rng(42); idx = randperm(numPatches); nVal = round(0.2*numPatches);
valIdx = idx(1:nVal); trainIdx = idx(nVal+1:end);
trainDS = allPatches(trainIdx);  valDS = allPatches(valIdx);

%% ===================== 5) MODEL ===========================
lgraph = buildUNet3D(config.patchSize, 3, config.baseFilters, 6);   % finite input size
net = dlnetwork(lgraph);

%% ===================== 6) TRAIN ===========================
mbqTrain = makeMinibatchQueue(trainDS, config.batchSize, useGPU);
mbqVal   = makeMinibatchQueue(valDS,   config.batchSize, useGPU);

trailingAvg = []; trailingAvgSq = [];
iter = 0; lr0 = config.learnRate;
totalIters = ceil(numel(trainDS)/config.batchSize) * config.maxEpochs;
bestVal = inf;

close all
% --- Figure setup (line plots) ---
figure('Name','Training Progress','Color','w');
tiledlayout(1,3,'TileSpacing','compact','Padding','compact');

% Tile 1: Train (last batch)
ax1 = nexttile(1); hold(ax1,'on'); grid(ax1,'on');
title(ax1,'Training Loss'); xlabel(ax1,'Epoch'); ylabel(ax1,'Loss');

% Tile 2: Val
ax2 = nexttile(2); hold(ax2,'on'); grid(ax2,'on');
title(ax2,'Validation Loss'); xlabel(ax2,'Epoch'); ylabel(ax2,'Loss');

% Tile 3: Both
ax3 = nexttile(3); hold(ax3,'on'); grid(ax3,'on');
title(ax3,'Train & Val'); xlabel(ax3,'Epoch'); ylabel(ax3,'Loss');

trainLossHist = nan(config.maxEpochs,1);
valLossHist   = nan(config.maxEpochs,1);

% Line handles (colors match across tiles)
trainLine = plot(ax1, nan, nan, 'b-', 'LineWidth', 1.8, 'DisplayName','Training');
valLine   = plot(ax2, nan, nan, 'r-', 'LineWidth', 1.8, 'DisplayName','Validation');

% Combined tile lines
trainLineBoth = plot(ax3, nan, nan, 'b-', 'LineWidth', 1.8, 'DisplayName','Training');
valLineBoth   = plot(ax3, nan, nan, 'r-', 'LineWidth', 1.8, 'DisplayName','Validation');
legend(ax3, 'Location','best');  % legend only on combined tile

trainLossHist = nan(config.maxEpochs,1);
valLossHist   = nan(config.maxEpochs,1);

trainLine = plot(ax1, nan, nan, 'b-', 'LineWidth', 1.8, 'DisplayName','Train (last batch)');
valLine   = plot(ax2, nan, nan, 'r-', 'LineWidth', 1.8, 'DisplayName','Val');

for epoch = 1:config.maxEpochs
    mbqTrain.reset();

    lastBatchLoss = NaN;   % will hold the loss from the final minibatch in this epoch
    batchCount = 0;

    while mbqTrain.hasdata()
        iter = iter + 1;
        lr = cosineLR(lr0, iter, totalIters);

        [X, refs, mask, acq, Smeas, sScale, edgeW] = mbqTrain.next();
        [loss, grads] = dlfeval(@modelGradients, net, X, refs, mask, acq, Smeas, sScale, edgeW, config);

        [net, trailingAvg, trailingAvgSq] = adamw_step(net, grads, ...
            trailingAvg, trailingAvgSq, lr, config.weightDecay, iter);

        lastBatchLoss = double(gather(extractdata(loss)));
        batchCount = batchCount + 1;

        if mod(iter,100)==0
            fprintf('Iter %6d | Epoch %3d | Batch %4d | LR %.2e | Loss %.2e\n', ...
                iter, epoch, batchCount, lr, lastBatchLoss);
        end
    end

    % --- End of epoch: use loss from the FINAL minibatch only ---
    trainLoss = lastBatchLoss;

    % Validation (as before)
    valLoss = evaluateVal(mbqVal, net, config);

    trainLossHist(epoch) = trainLoss;
    valLossHist(epoch)   = valLoss;

    fprintf('==== Epoch %3d/%3d done | Training Loss = %.2e | Validation Loss = %.2e ====\n', ...
        epoch, config.maxEpochs, trainLoss, valLoss);


    % --- Update line plots on all tiles ---
    set(trainLine,     'XData', 1:epoch, 'YData', trainLossHist(1:epoch));
    set(valLine,       'XData', 1:epoch, 'YData', valLossHist(1:epoch));
    set(trainLineBoth, 'XData', 1:epoch, 'YData', trainLossHist(1:epoch));
    set(valLineBoth,   'XData', 1:epoch, 'YData', valLossHist(1:epoch));
    drawnow limitrate;


    % Checkpoints
    if valLoss < bestVal
        bestVal = valLoss;
        save(fullfile(config.outDir, sprintf('best_epoch.mat',epoch,valLoss)), 'net','config','epoch','valLoss','trainLoss');
    end
    if mod(epoch, config.ckptEvery)==0
        save(fullfile(config.outDir, sprintf('epoch%03d.mat',epoch)), 'net','config');
    end
end
figure(1)
allTextObjects = findall(gcf, '-property', 'FontName');
    set(allTextObjects, 'FontName', 'Times New Roman', 'FontSize', 12);

saveas(gcf,fullfile(config.outDir,'LossesFigure.png'))
saveas(gcf,fullfile(config.outDir,'LossesFigure.fig'))
fprintf('Done. Best val = %.2e\n', bestVal);
end
%% ===================== LOCAL FUNCTIONS ====================

function tf = canUseGPU()
tf = false; try, tf = gpuDeviceCount>0; catch, end
end

function V = readNii(fp)
try, V = niftiread(fp); catch, error('Failed to read: %s', fp); end
V = single(V);
end

function [S1,S2,S3] = normalizeContrasts(S1,S2,S3,M)
S = {S1,S2,S3};
for i=1:3
    v = S{i}; vi = v(M);
    p1 = prctile(vi,1); p99 = prctile(vi,99);
    v = min(max(v,p1), p99);
    mu = mean(v(M),'omitnan'); sd = std(v(M),1,'omitnan');
    S{i} = (v - mu) / max(sd,1e-6);
end
S1 = S{1}; S2 = S{2}; S3 = S{3};
end

function patches = extractPatches3D(S1,S2,S3,PD,T1,T2,M,ps,st)
% Extract overlapping 3D patches; require >=20% mask coverage
sz = size(M); idxs = [];
for z=1:st(1):max(1,sz(1)-ps(1)+1)
    for y=1:st(2):max(1,sz(2)-ps(2)+1)
        for x=1:st(3):max(1,sz(3)-ps(3)+1)
            m = M(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1);
            if nnz(m) < 0.2*numel(m), continue; end
            idxs(end+1,:)=[z y x];
        end
    end
end

patches = cell(size(idxs,1),1);
parfor i=1:size(idxs,1)
    z=idxs(i,1); y=idxs(i,2); x=idxs(i,3);

    images = cat(4, ...
        S1(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1), ...
        S2(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1), ...
        S3(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1));    % (ps) x 3
    images = permute(images,[4 1 2 3]);                % (C,Z,Y,X)

    PDp = PD(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1);
    T1p = T1(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1);
    T2p = T2(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1);
    Mp  =  M(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1);

    patches{i} = struct( ...
        'images', single(images), ...
        'PD',     single(PDp), ...
        'T1',     single(T1p), ...
        'T2',     single(T2p), ...
        'mask',   logical(Mp) );
end
end

function mbq = makeMinibatchQueue(ds, batchSize, useGPU)
% Returns batches with MATLAB 3D format:
% X/Smeas: [Z Y X C N] -> 'SSSCB'; Maps/Mask: [Z Y X N] -> 'SSSB'
num   = numel(ds);
order = randperm(num);
idx   = 1;  % cursor

    function reset()
        order = randperm(num);
        idx   = 1;
    end

    function tf = hasdata()
        tf = (idx <= num);
    end

    function [X, refs, M, A, S, sScale, edgeW] = next()
        assert(idx <= num, 'No more data in minibatch queue. Call reset() or check hasdata().');

        i0  = idx;
        i1  = min(num, idx + batchSize - 1);
        sel = order(i0:i1);
        idx = i1 + 1;

        % infer sizes from first sample
        C = size(ds{sel(1)}.images,1);               % should be 3
        psizeCZYX = size(ds{sel(1)}.images);
        psize = psizeCZYX(2:4);                      % [Z Y X]

        Xczyxn = zeros(C, psize(1), psize(2), psize(3), numel(sel), 'single');
        PDn    = zeros(psize(1), psize(2), psize(3), numel(sel), 'single');
        T1n    = PDn;
        T2n    = PDn;
        Mn     = false(psize(1), psize(2), psize(3), numel(sel));
        Smeasc = zeros(C, psize(1), psize(2), psize(3), numel(sel), 'single');
        ACQ    = zeros(8, numel(sel), 'single');

        for j=1:numel(sel)
            d = ds{sel(j)};
            Xczyxn(:,:,:,:,j)  = d.images;
            Smeasc(:,:,:,:,j)  = d.images;      % inputs are the measured signals
            PDn(:,:,:,j)       = d.PD;
            T1n(:,:,:,j)       = d.T1;
            T2n(:,:,:,j)       = d.T2;
            Mn (:,:,:,j)       = d.mask;
            if isfield(d,'acq'), ACQ(:,j)=d.acq(:); end
        end

        % Convert (C,Z,Y,X,N) -> (Z,Y,X,C,N)
        X = permute(Xczyxn, [2 3 4 1 5]);
        S = permute(Smeasc, [2 3 4 1 5]);

        % Per-contrast robust scales
        sScale = single([1 1 1]);

        % Edge weights from inputs (per-batch)
        edgeW = computeEdgeWeights(X, Mn);  % returns 'SSSB'

        % dlarray + device tags
        X = dlarray(X,   'SSSCB');
        S = dlarray(S,   'SSSCB');
        M = dlarray(Mn,  'SSSB');
        A = dlarray(ACQ, 'CB');     % (8,B)

        PDd = dlarray(PDn, 'SSSB');
        T1d = dlarray(T1n, 'SSSB');
        T2d = dlarray(T2n, 'SSSB');

        if useGPU
            [X,S,M,A,PDd,T1d,T2d,edgeW] = deal(gpuArray(X),gpuArray(S),gpuArray(M),gpuArray(A),gpuArray(PDd),gpuArray(T1d),gpuArray(T2d),gpuArray(edgeW));
        end

        refs = struct('PD',PDd,'T1',T1d,'T2',T2d);
    end

% expose as a simple object-like struct
mbq.reset   = @reset;
mbq.hasdata = @hasdata;
mbq.next    = @next;
mbq.NumObservations = num;
end


function W = computeEdgeWeights(X, M)
% X: [Z Y X C N], M: [Z Y X N] (logical)
% Edge weight w = |grad| averaged over contrasts (kappa applied in loss)
C = size(X,4);
gsum = zeros(size(M), 'like', X);
for c = 1:C
    Xi = squeeze(X(:,:,:,c,:)); % [Z Y X N]
    [gx,gy,gz] = grad3D(Xi);
    gmag = sqrt(gx.^2 + gy.^2 + gz.^2);
    gsum = gsum + gmag;
end
gsum = gsum / C;
W = dlarray(gsum, 'SSSB') .* M;
end

function [gx,gy,gz] = grad3D(V)
% Central differences with zero-Neumann borders
gx = zeros(size(V),'like',V); gy = gx; gz = gx;
gx(2:end-1,:,:,:) = 0.5*(V(3:end,:,:,:) - V(1:end-2,:,:,:));
gy(:,2:end-1,:,:) = 0.5*(V(:,3:end,:,:) - V(:,1:end-2,:,:));
gz(:,:,2:end-1,:) = 0.5*(V(:,:,3:end,:) - V(:,:,1:end-2,:));
end

%% --------------- U-NET (finite input, matching scales) --------------------
function lgraph = buildUNet3D(patchSize, inCh, base, outCh)
% Single-input 3D U-Net; upsample blocks concat with matching-scale encoder.
import nnet.cnn.layer.*
Z = patchSize(1); Y = patchSize(2); X = patchSize(3);

lgraph = layerGraph();

% Input
inL = image3dInputLayer([Z Y X inCh], 'Normalization','none', 'Name','in');
lgraph = addLayers(lgraph, inL);

% Encoder: enc1(S) -> enc2(S/2) -> enc3(S/4) -> enc4(S/8)
enc1 = encBlockLayers(base, 'enc1');
lgraph = addLayers(lgraph, enc1);
lgraph = connectLayers(lgraph,'in','enc1_c1');

enc2 = downBlockLayers(base, 2*base, 'enc2');
lgraph = addLayers(lgraph, enc2);
lgraph = connectLayers(lgraph,'enc1_out','enc2_pool');

enc3 = downBlockLayers(2*base, 4*base, 'enc3');
lgraph = addLayers(lgraph, enc3);
lgraph = connectLayers(lgraph,'enc2_out','enc3_pool');

enc4 = downBlockLayers(4*base, 8*base, 'enc4');
lgraph = addLayers(lgraph, enc4);
lgraph = connectLayers(lgraph,'enc3_out','enc4_pool');

% Bottleneck (still S/8)
bott = encBlockLayers(16*base, 'bott');
lgraph = addLayers(lgraph, bott);
lgraph = connectLayers(lgraph,'enc4_out','bott_c1');

% Decoder: up3 (→S/4 concat enc3), up2 (→S/2 concat enc2), up1 (→S concat enc1)
up3 = upBlockLayers(16*base, 8*base, 'up3');  % output channels 8*base at S/4
lgraph = addLayers(lgraph, up3);
lgraph = connectLayers(lgraph,'bott_out','up3_up');
% implicit up3_up->up3_cat/in1 exists; add skip from enc3
lgraph = connectLayers(lgraph,'enc3_out','up3_cat/in2');

up2 = upBlockLayers(8*base, 4*base, 'up2');   % S/4->S/2, skip enc2
lgraph = addLayers(lgraph, up2);
lgraph = connectLayers(lgraph,'up3_out','up2_up');
lgraph = connectLayers(lgraph,'enc2_out','up2_cat/in2');

up1 = upBlockLayers(4*base, 2*base, 'up1');   % S/2->S, skip enc1
lgraph = addLayers(lgraph, up1);
lgraph = connectLayers(lgraph,'up2_out','up1_up');
lgraph = connectLayers(lgraph,'enc1_out','up1_cat/in2');

% Final head from up1_out (S)
final = convolution3dLayer(1,outCh,'Name','final');
lgraph = addLayers(lgraph, final);
lgraph = connectLayers(lgraph,'up1_out','final');
end

function layers = encBlockLayers(outF, tag)
import nnet.cnn.layer.*
layers = [
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c1'])
    groupNormalizationLayer('all-channels','Name',[tag '_gn1'])
    geluLayer('Name',[tag '_g1'])
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c2'])
    groupNormalizationLayer('all-channels','Name',[tag '_gn2'])
    geluLayer('Name',[tag '_out'])
    ];
end

function layers = downBlockLayers(inF, outF, tag)
import nnet.cnn.layer.*
layers = [
    maxPooling3dLayer(2,'Stride',2,'Name',[tag '_pool'])
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c1'])
    groupNormalizationLayer('all-channels','Name',[tag '_gn1'])
    geluLayer('Name',[tag '_g1'])
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c2'])
    groupNormalizationLayer('all-channels','Name',[tag '_out'])
    ];
end

function layers = upBlockLayers(inF, outF, tag)
import nnet.cnn.layer.*
layers = [
    transposedConv3dLayer(2,outF,'Stride',2,'Name',[tag '_up'])
    depthConcatenationLayer(2,'Name',[tag '_cat'])
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c1'])
    groupNormalizationLayer('all-channels','Name',[tag '_gn1'])
    geluLayer('Name',[tag '_g1'])
    convolution3dLayer(3,outF,'Padding','same','Name',[tag '_c2'])
    groupNormalizationLayer('all-channels','Name',[tag '_out'])
    ];
end

%% --------------- Training Step / Losses -------------------
function [loss, grads] = modelGradients(net, X, refs, M, ACQ, Smeas, sScale, edgeW, cfg)
% % X,Smeas: [Z Y X C N] 'SSSCB' ; refs/M/edgeW: [Z Y X N] 'SSSB'
Y = forward(net, X);                 % Y: [Z Y X 6 N]
PDraw = Y(:,:,:,1,:);                % PD raw (to sigmoid)
T1raw = Y(:,:,:,2,:);                % map to (0, T1max]
T2raw = Y(:,:,:,3,:);                % map to (0, T2max]
logg1 = Y(:,:,:,4,:);                % >0 via exp
logg2 = Y(:,:,:,5,:);
logg3 = Y(:,:,:,6,:);

% % HARD CAPS via scaled sigmoid
PD = cfg.PDmax * sigmoid(PDraw);     % [0,150]
T1 = cfg.T1max * sigmoid(T1raw);     % (0,5000]
T2 = cfg.T2max * sigmoid(T2raw);     % (0,3000]
g1 = cfg.g1max * sigmoid(logg1);
g2 = cfg.g2max * sigmoid(logg2);
g3 = cfg.g3max * sigmoid(logg3);

% % Optional: clean background using mask
PD(~M)=0; T1(~M)=0; T2(~M)=0; g1(~M)=0; g2(~M)=0; g3(~M)=0;

% Physics synthesis (no T2* in GRE)
[S1,S2,S3] = synthSignals(PD,T1,T2,g1,g2,g3,ACQ);

% ----------------- SIGNAL LOSS (masked L1) -----------------
d1 = abs(S1 - Smeas(:,:,:,1,:)) .* M;
d2 = abs(S2 - Smeas(:,:,:,2,:)) .* M;
d3 = abs(S3 - Smeas(:,:,:,3,:)) .* M;

Lsig = sum(d1,'all') * cfg.wSignal(1) + ...
       sum(d2,'all') * cfg.wSignal(2) + ...
       sum(d3,'all') * cfg.wSignal(3);

% ----------------- PARAM LOSS (masked L1) ------------------
Lpar =  cfg.lamPD * sum(abs((PD  - refs.PD).*M), 'all') + ...
        cfg.lamT1 * sum(abs((T1  - refs.T1).*M), 'all') + ...
        cfg.lamT2 * sum(abs((T2  - refs.T2).*M), 'all');

%%
% % Regularization
% W = exp(-cfg.kappaEdge * edgeW) .* M; % edge-aware weight in mask
% Ltv_PD = cfg.tvPD * tvCharb(PD,   W, cfg.epsTV);
% % Regularize in log-space for T1/T2 for numeric stability
% Ltv_T1 = cfg.tvT1 * tvCharb(log(T1 + 1e-8), W, cfg.epsTV);
% Ltv_T2 = cfg.tvT2 * tvCharb(log(T2 + 1e-8), W, cfg.epsTV);
% 
% % Gain smoothness (L2 of spatial gradients)
% Lsm_g  = cfg.smoothG * ( l2smooth(g1,M) + l2smooth(g2,M) + l2smooth(g3,M) );
% 
% loss = Lsig + Lpar + Ltv_PD + Ltv_T1 + Ltv_T2 + Lsm_g;

loss = Lsig + Lpar;

grads = dlgradient(loss, net.Learnables);
end

function [S1,S2,S3] = synthSignals(PD,T1,T2,g1,g2,g3,ACQ)
% ACQ: (8,B) -> [TRT1,TET1,FAT1rad,TRT2,TET2,TRF,TEF,TIF]
TRT1 = reshape(ACQ(1,:),1,1,1,1,[]);
FAT1 = reshape(ACQ(3,:),1,1,1,1,[]);
TRT2 = reshape(ACQ(4,:),1,1,1,1,[]);
TET2 = reshape(ACQ(5,:),1,1,1,1,[]);
TRF  = reshape(ACQ(6,:),1,1,1,1,[]);
TEF  = reshape(ACQ(7,:),1,1,1,1,[]);
TIF  = reshape(ACQ(8,:),1,1,1,1,[]);

num = (1 - exp(-TRT1 ./ T1)) .* sin(FAT1);
den = 1 - cos(FAT1) .* exp(-TRT1 ./ T1);
S1  = g1 .* PD .* (num ./ (den + 1e-8));                           % T1w GRE (no T2*)
S2  = g2 .* PD .* (1 - exp(-TRT2 ./ T1)) .* exp(-TET2 ./ T2);      % T2w SE
S3  = g3 .* PD .* (1 - 2*exp(-TIF ./ T1) + exp(-TRF ./ T1)) .* ...
    exp(-TEF ./ T2);                                      % FLAIR
% Example for one dlarray
S1(~isfinite(S1)) = 0;
S2(~isfinite(S2)) = 0;
S3(~isfinite(S3)) = 0;

end
function y = sigmoid(x), y = 1./(1+exp(-x)); end

function L = huber(R, delta, M)
A = abs(R);
h = (A<=delta).*0.5.*R.*R + (A>delta).* (delta.*(A - 0.5*delta));
L = meanMasked(h, M);
end

function m = meanMasked(X, M)
X = X .* M; m = sum(X,'all') / (sum(M,'all') + eps);
end

function L = tvCharb(Q, W, epsTV)
[dx,dy,dz] = grad3D(Q);
L = meanMasked( sqrt( (W.*dx).^2 + (W.*dy).^2 + (W.*dz).^2 + epsTV^2 ), ones(size(W),'like',W) );
end

function L = l2smooth(Q, M)
[dx,dy,dz] = grad3D(Q);
L = meanMasked( dx.^2 + dy.^2 + dz.^2, M );
end

function valLoss = evaluateVal(mbqVal, net, cfg)
mbqVal.reset(); tot=0; n=0;
while mbqVal.hasdata()
    [X, refs, M, ACQ, Smeas, sScale, edgeW] = mbqVal.next();
    loss = dlfeval(@modelGradients, net, X, refs, M, ACQ, Smeas, sScale, edgeW, cfg);
    tot = tot + double(gather(extractdata(loss))); n = n + 1;
end
valLoss = tot / max(1,n);
end

function lr = cosineLR(lr0, step, totalSteps), t=step/max(1,totalSteps); lr=0.5*lr0*(1+cos(pi*t)); end

function [net, trailingAvg, trailingAvgSq] = adamw_step(net, grads, trailingAvg, trailingAvgSq, lr, wd, iter)
% Stable AdamW using MATLAB's adamupdate + decoupled weight decay via dlupdate.
% - net:       dlnetwork
% - grads:     table of gradients from dlfeval(@modelGradients,...)
% - trailing*: Adam moment buffers (pass [] on first call)
% - lr:        learning rate (scalar)
% - wd:        weight decay (L2) coefficient
% - iter:      current iteration (1-based)

% Adam step (updates learnables using grads; handles tables safely)
beta1 = 0.9; beta2 = 0.999;
[net, trailingAvg, trailingAvgSq] = adamupdate(net, grads, ...
    trailingAvg, trailingAvgSq, iter, lr, beta1, beta2);

% Decoupled weight decay (apply to all learnables)
if wd > 0
    decay = @(p) p - lr * wd * p;
    net = dlupdate(decay, net);
end
end