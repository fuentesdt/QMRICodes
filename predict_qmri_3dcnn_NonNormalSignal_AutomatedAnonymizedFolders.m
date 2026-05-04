% ===============================================================
% qMRI 3D CNN Inference & Saving
% - Loads trained net + config (choose .mat)
% - Reads ONE master Excel file from root folder: acq_params.xlsx
% - Infers LOPO fold from trained model folder name, e.g. trained_models_P1
% - Maps P1/P2/... to the corresponding patient row order in Excel
% - Asks whether to predict:
%       (1) held-out patient only
%       (2) all patients
% - Loads T1w/T2w/FLAIR (+ optional mask)
% - Runs sliding-window prediction (GPU if present)
% - Saves PD/T1/T2/g1/g2/g3 as NIfTI in an identifiable output folder
% - Synthesizes signals from predictions and saves as NIfTI, too
% ===============================================================

clc; clear; close all;

fprintf('=== qMRI 3D CNN Inference ===\n');

%% 0) Select trained model (.mat containing variables `net` and optionally `config`)
[matFile, matPath] = uigetfile({'*.mat','MAT-files (*.mat)'}, ...
    'Select trained model (contains net, config)');
if isequal(matFile,0) || isequal(matPath,0)
    error('Model selection cancelled.');
end

S = load(fullfile(matPath, matFile));
assert(isfield(S,'net'), 'Selected .mat does not contain variable `net`.');
net = S.net;

if isfield(S,'config')
    cfgTr = S.config;
else
    cfgTr = struct();
end

%% 1) Select root folder containing patient subfolders and master Excel
rootDir = uigetdir(pwd, 'Select ROOT folder containing acq_params.xlsx and patient folders');
if isequal(rootDir,0)
    error('Root folder selection cancelled.');
end

%% 2) Read master Excel file with ALL patients
excelPath = fullfile(rootDir, 'acq_params.xlsx');
assert(isfile(excelPath), 'Could not find acq_params.xlsx in root folder: %s', rootDir);

T = readtable(excelPath);

% Resolve expected column names
idCol   = pickVar(T, ["PatientID","ID","Subject","SubjectID"]);
TRT1col = pickVar(T, ["TRT1","TR_T1","TR_Gre","TR_SPGR","TR_T1w"]);
TET1col = pickVar(T, ["TET1","TE_T1","TE_Gre","TE_SPGR","TE_T1w"]);
FADcol  = pickVar(T, ["FAT1_deg","FA_deg","Flip_deg","FA","FlipAngle_deg"]);
TRT2col = pickVar(T, ["TRT2","TR_SE","TR_T2","TR_T2w"]);
TET2col = pickVar(T, ["TET2","TE_SE","TE_T2","TE_T2w"]);
TRFcol  = pickVar(T, ["TRFLAIR","TR_FLAIR","TR_IR"]);
TEFcol  = pickVar(T, ["TEFLAIR","TE_FLAIR"]);
TIFcol  = pickVar(T, ["TIFLAIR","TI","TI_FLAIR"]);

patientIDs = strtrim(string(T.(idCol)));
patientIDs = patientIDs(~ismissing(patientIDs) & strlength(patientIDs)>0);

assert(~isempty(patientIDs), 'No valid patient IDs found in Excel.');

%% 3) Detect LOPO fold from trained model folder name
modelFolder = string(getLastFolderName(matPath));

% Detect model type from selected model folder
% Accepted folder names:
%   trained_models_all
%   trained_models_LeftOut_P0001, trained_models_LeftOut_P0002, ...

tokens = regexp(modelFolder, '^trained_models_LeftOut_(P\d{4})$', 'tokens');

if strcmpi(modelFolder, 'trained_models_all')

    modelMode = "all";
    leftOutID = "";
    savedir   = "All_Pred";

elseif ~isempty(tokens)

    modelMode = "lopo";
    leftOutID = string(tokens{1}{1});   % e.g., "P0001"

    % Check that this left-out patient exists in Excel
    if ~any(patientIDs == leftOutID)
        error('Left-out patient %s from model folder was not found in Excel PatientID column.', leftOutID);
    end

    savedir = leftOutID + "_Left_Predictions";

else
    error(['Model folder name must be either trained_models_all ', ...
        'or trained_models_LeftOut_P0001, trained_models_LeftOut_P0002, etc.']);
end
%% 3.1) Ask whether to predict held-out patient only or all patients
% Decide which patients to predict
if modelMode == "all"
    fprintf('Model trained on all patients selected. Predicting all patients.\n');
    predictIDs = patientIDs;
else
    choice = questdlg('Which patients do you want to predict?', ...
        'Prediction mode', ...
        'Held-out patient only', 'All patients', ...
        'Held-out patient only');

    if strcmp(choice, 'Held-out patient only')
        predictIDs = leftOutID;
    else
        predictIDs = patientIDs;
    end
end


fprintf('Prediction output folder name: %s\n', savedir);

%% 3.2) Loop over selected patients
for sel = 1:numel(predictIDs)

    close all

    pid  = predictIDs(sel);
    pdir = fullfile(rootDir, pid);

    assert(isfolder(pdir), 'Patient folder not found: %s', pdir);

    fprintf('\nSelected patient: %s\n', pid);

    if ~exist(fullfile(pdir, savedir), 'dir')
        mkdir(fullfile(pdir, savedir));
    end

    savefolder = fullfile(pdir, savedir);

    %% 4) Locate & load patient data
    % === File name definitions for this dataset ===
    config.fileT1w     = "PREOP_T1_W_S.nii.gz";
    config.fileT2w     = "PREOP_AxT2_W_S.nii.gz";
    config.fileFLAIR   = "PREOP_FLAIR_W_S.nii.gz";
    config.filePDref   = "pdmap.nii.gz";
    config.fileT1ref   = "t1map.nii.gz";
    config.fileT2ref   = "t2map.nii.gz";

    % === Locate patient files ===
    fileT1w   = matchExisting(pdir, [config.fileT1w, erase(config.fileT1w,".gz")]);
    fileT2w   = matchExisting(pdir, [config.fileT2w, erase(config.fileT2w,".gz")]);
    fileFLAIR = matchExisting(pdir, [config.fileFLAIR, erase(config.fileFLAIR,".gz")]);

    filePDref = matchExisting(pdir, [config.filePDref, erase(config.filePDref,".gz")]);
    fileT1ref = matchExisting(pdir, [config.fileT1ref, erase(config.fileT1ref,".gz")]);
    fileT2ref = matchExisting(pdir, [config.fileT2ref, erase(config.fileT2ref,".gz")]);

    fileMask  = matchExisting(pdir, ["mask.nii.gz","mask.nii"], true); % optional mask

    S1  = readNii(fullfile(pdir,fileT1w));
    infoRef = niftiinfo(fullfile(pdir,fileT1w));

    S2  = readNii(fullfile(pdir,fileT2w));
    S3  = readNii(fullfile(pdir,fileFLAIR));

    PDSyMRI  = readNii(fullfile(pdir,filePDref));
    T1SyMRI  = readNii(fullfile(pdir,fileT1ref));
    T2SyMRI  = readNii(fullfile(pdir,fileT2ref));

    if ~isempty(fileMask)
        M = logical(readNii(fullfile(pdir,fileMask)));
    else
        M = true(size(S1),'like',S1);
    end

    assert(isequal(size(S1),size(S2),size(S3),size(M)), ...
        'Input/mask sizes do not match for patient %s.', pid);

    assert(isequal(size(S1),size(PDSyMRI),size(T1SyMRI),size(T2SyMRI)), ...
        'Input/reference qMRI map sizes do not match for patient %s.', pid);

    %% 5) Acquisition parameters for this patient
    row = T(strcmp(strtrim(string(T.(idCol))), pid), :);
    assert(~isempty(row),'Patient %s not found in Excel.', pid);

    ACQ = zeros(8,1,'single');
    ACQ(1) = single(row.(TRT1col));                % TR T1w
    ACQ(2) = single(row.(TET1col));                % TE T1w
    ACQ(3) = single(deg2rad(row.(FADcol)));        % FA in radians
    ACQ(4) = single(row.(TRT2col));                % TR T2w
    ACQ(5) = single(row.(TET2col));                % TE T2w
    ACQ(6) = single(row.(TRFcol));                 % TR FLAIR
    ACQ(7) = single(row.(TEFcol));                 % TE FLAIR
    ACQ(8) = single(row.(TIFcol));                 % TI FLAIR

    %% 6) Raw inputs
    Xfull = cat(4, S1, S2, S3);                  % [Z Y X C]

    %% 7) Patch size & stride
    if isfield(cfgTr,'patchSize') && numel(cfgTr.patchSize)==3
        patchSize = cfgTr.patchSize;             % [Z Y X]
    else
        patchSize = [64 64 64];
    end

    stride = max(1, floor(patchSize/4));

    %% 8) Sliding-window inference
    useGPU = canUseGPU();
    fprintf('Running inference on %s ...\n', ternary(useGPU,'GPU','CPU'));

    [PDraw,T1raw,T2raw,g1raw,g2raw,g3raw] = slidingPredict(net, Xfull, patchSize, stride, useGPU);

    %% 8.1) Enforce physical caps as in training
    PDmax = pickField(cfgTr,'PDmax',150);
    T1max = pickField(cfgTr,'T1max',5000);
    T2max = pickField(cfgTr,'T2max',3000);
    g1max = pickField(cfgTr,'g1max',500);
    g2max = pickField(cfgTr,'g2max',500);
    g3max = pickField(cfgTr,'g3max',500);

    % HARD CAPS via scaled sigmoid
    PD = PDmax * sigmoid(PDraw);     % [0,150]
    T1 = T1max * sigmoid(T1raw);     % (0,5000]
    T2 = T2max * sigmoid(T2raw);     % (0,3000]
    g1 = g1max * sigmoid(g1raw);
    g2 = g2max * sigmoid(g2raw);
    g3 = g3max * sigmoid(g3raw);

    % Apply light 3D Gaussian smoothing
    sigma = 0.1;
    PD = imgaussfilt3(PD, sigma);
    T1 = imgaussfilt3(T1, sigma);
    T2 = imgaussfilt3(T2, sigma);
    g1 = imgaussfilt3(g1, sigma);
    g2 = imgaussfilt3(g2, sigma);
    g3 = imgaussfilt3(g3, sigma);

    % Optional: clean background using mask
    PD(~M)=0; T1(~M)=0; T2(~M)=0; g1(~M)=0; g2(~M)=0; g3(~M)=0;

    %% 9) Synthesize signals from predictions
    ACQb = reshape(ACQ, [8 1]);
    [S1calc,S2calc,S3calc] = synthSignals(PD,T1,T2,g1,g2,g3,ACQb);

    maxS1 = max(S1,[],'all');
    maxS2 = max(S2,[],'all');
    maxS3 = max(S3,[],'all');

    minS1 = min(S1,[],'all');
    minS2 = min(S2,[],'all');
    minS3 = min(S3,[],'all');

    % Clip synthesized signals to measured signal ranges.
    % S3 bounding mismatch corrected here: S3 uses maxS3/minS3, not maxS2/minS2.
    S1calc(S1calc>maxS1) = maxS1;
    S2calc(S2calc>maxS2) = maxS2;
    S3calc(S3calc>maxS3) = maxS3;

    S1calc(S1calc<minS1) = minS1;
    S2calc(S2calc<minS2) = minS2;
    S3calc(S3calc<minS3) = minS3;

    %% Training-style inference loss
    % ----------------- SIGNAL LOSS (masked L1) -----------------
    d1 = abs(S1 - S1calc).*M;
    d2 = abs(S2 - S2calc).*M;
    d3 = abs(S3 - S3calc).*M;

    wSignal = pickField(cfgTr,'wSignal',[1 1 1]);
    lamPD   = pickField(cfgTr,'lamPD',1.0);
    lamT1   = pickField(cfgTr,'lamT1',1.0);
    lamT2   = pickField(cfgTr,'lamT2',1.0);

    Lsig = sum(d1,'all') * wSignal(1) + ...
        sum(d2,'all') * wSignal(2) + ...
        sum(d3,'all') * wSignal(3);

    % ----------------- PARAM LOSS (masked L1) ------------------
    Lpar = lamPD * sum(abs((PD  - PDSyMRI).*M),'all') + ...
        lamT1 * sum(abs((T1  - T1SyMRI).*M),'all') + ...
        lamT2 * sum(abs((T2  - T2SyMRI).*M),'all');

    TestLoss = Lsig + Lpar;

    if isfield(S,'trainLoss')
        trainLoss = S.trainLoss;
    else
        trainLoss = NaN;
    end

    if isfield(S,'valLoss')
        valLoss = S.valLoss;
    else
        valLoss = NaN;
    end

    fprintf('--- Inference losses (training-style) ---\n');
    fprintf('  Lsig = %.6g\n', Lsig);
    fprintf('  Lpar = %.6g\n', Lpar);
    fprintf('  Loss = %.6g\n', TestLoss);
    fprintf('--- Training losses from selected model file ---\n');
    fprintf('  Training Loss = %.6g\n', trainLoss);
    fprintf('  Validation Loss = %.6g\n', valLoss);


    if modelMode == "all"
        save(fullfile(savefolder,"TestLosses.mat"), ...
            "Lsig","Lpar","TestLoss","trainLoss","valLoss", ...
            "modelMode","pid","savedir");
    else
        save(fullfile(savefolder,"TestLosses.mat"), ...
            "Lsig","Lpar","TestLoss","trainLoss","valLoss", ...
            "modelMode","leftOutID","pid","savedir");
    end

    %% Plotting and correlation
    cccPD = ccc_barnes(PD(M==1),PDSyMRI(M==1));
    cccT1 = ccc_barnes(T1(M==1),T1SyMRI(M==1));
    cccT2 = ccc_barnes(T2(M==1),T2SyMRI(M==1));
    cccS1 = ccc_barnes(S1(M==1),S1calc(M==1));
    cccS2 = ccc_barnes(S2(M==1),S2calc(M==1));
    cccS3 = ccc_barnes(S3(M==1),S3calc(M==1));

    % Use only mask voxels for plotting, randomly subsampled
    idxMask = find(M==1);
    nPlot = max(1, round(0.25*numel(idxMask)));
    nPlot = min(nPlot, numel(idxMask));
    idxPlot = idxMask(randperm(numel(idxMask), nPlot));

    S1_meas = S1(idxPlot);
    S2_meas = S2(idxPlot);
    SF_meas = S3(idxPlot);

    S1_pred = S1calc(idxPlot);
    S2_pred = S2calc(idxPlot);
    SF_pred = S3calc(idxPlot);

    figure('Name','Measured vs Predicted Comparison','Color','w');
    tiledlayout(2,3,'Padding','compact','TileSpacing','compact');

    nexttile;
    scatter(S1_meas, S1_pred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('T1W raw data'); ylabel('T1W model'); title(sprintf('T1W, CCC = %.2f',cccS1));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    nexttile;
    scatter(S2_meas, S2_pred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('T2W raw data'); ylabel('T2W model'); title(sprintf('T2W, CCC = %.2f',cccS2));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    nexttile;
    scatter(SF_meas, SF_pred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('FLAIR raw data'); ylabel('FLAIR model'); title(sprintf('FLAIR, CCC = %.2f',cccS3));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    PDobs = PDSyMRI(idxPlot);
    T1obs = T1SyMRI(idxPlot);
    T2obs = T2SyMRI(idxPlot);

    PDpred = PD(idxPlot);
    T1pred = T1(idxPlot);
    T2pred = T2(idxPlot);

    nexttile;
    scatter(PDobs, PDpred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('PD SyMRI'); ylabel('PD Pred'); title(sprintf('PD, CCC = %.2f',cccPD));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    nexttile;
    scatter(T1obs, T1pred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('T1 SyMRI'); ylabel('T1 Pred'); title(sprintf('T1, CCC = %.2f',cccT1));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    nexttile;
    scatter(T2obs, T2pred, 6, 'filled'); hold on; grid on; axis square; axis tight;
    xlabel('T2 SyMRI'); ylabel('T2 Pred'); title(sprintf('T2, CCC = %.2f',cccT2));
    lims = [min([xlim ylim]) max([xlim ylim])]; plot(lims,lims,'k--'); xlim(lims); ylim(lims);

    allTextObjects = findall(gcf, '-property', 'FontName');
    set(allTextObjects, 'FontName', 'Times New Roman', 'FontSize', 12);

    saveas(gcf,fullfile(savefolder,'Comparison.png'));
    saveas(gcf,fullfile(savefolder,'Comparison.fig'));

    %% 10) Save outputs as NIfTI in patient folder
    fprintf('Saving outputs to: %s\n', savefolder);

    writeLike(fullfile(savefolder,'PD_pred.nii.gz'),       PD, infoRef);
    writeLike(fullfile(savefolder,'T1_pred_ms.nii.gz'),    T1, infoRef);
    writeLike(fullfile(savefolder,'T2_pred_ms.nii.gz'),    T2, infoRef);
    writeLike(fullfile(savefolder,'g1_pred.nii.gz'),       g1, infoRef);
    writeLike(fullfile(savefolder,'g2_pred.nii.gz'),       g2, infoRef);
    writeLike(fullfile(savefolder,'g3_pred.nii.gz'),       g3, infoRef);

    writeLike(fullfile(savefolder,'T1w_calc.nii.gz'),      S1calc, infoRef);
    writeLike(fullfile(savefolder,'T2w_calc.nii.gz'),      S2calc, infoRef);
    writeLike(fullfile(savefolder,'FLAIR_calc.nii.gz'),    S3calc, infoRef);

    fprintf('PID: %s Prediction Done. ✅\n', pid);

end % loop over selected patients


%% ======================== HELPERS =========================

function name = getLastFolderName(pathstr)
pathstr = char(pathstr);

if endsWith(pathstr, filesep)
    pathstr = pathstr(1:end-1);
end

[~, name] = fileparts(pathstr);
end


function name = pickVar(T, candidates)
% Return the first matching column name (case-insensitive)
for i=1:numel(candidates)
    if any(strcmpi(T.Properties.VariableNames, candidates(i)))
        name = candidates(i);
        return;
    end
end
error('Excel is missing required column. Tried any of: %s', strjoin(string(candidates),', '));
end


function out = pickField(S, field, defaultValue)
if nargin < 3
    defaultValue = [];
end

if isempty(S) || ~isfield(S,field)
    if isempty(defaultValue)
        error('Required field "%s" is missing from config.', field);
    else
        warning('Field "%s" missing from config. Using default value.', field);
        out = defaultValue;
    end
else
    out = S.(field);
end
end


function tf = canUseGPU()
tf = false;
try
    tf = gpuDeviceCount > 0;
catch
end
end


function s = ternary(cond,a,b)
if cond
    s = a;
else
    s = b;
end
end


function V = readNii(fp)
V = niftiread(fp);
V = single(V);
end


function writeLike(fpOut, V, infoRef)
info = infoRef;
info.ImageSize = size(V);
V = single(V);

try
    info.Datatype = 'single';
catch
end

% Write .nii or .nii.gz
if endsWith(lower(fpOut), '.nii.gz')
    tmp = erase(fpOut, '.gz');
    niftiwrite(V, tmp, info, 'Compressed', false);
    gzip(tmp);
    delete(tmp);
else
    niftiwrite(V, fpOut, info, 'Compressed', true);
end
end


function file = matchExisting(folder, candidates, optional)
if nargin < 3
    optional = false;
end

for i=1:numel(candidates)
    if isfile(fullfile(folder, candidates(i)))
        file = candidates(i);
        return;
    end
end

if optional
    file = '';
else
    error('Missing required file in %s. Tried: %s', folder, strjoin(string(candidates),', '));
end
end


function [S1,S2,S3] = normalizeContrasts(S1,S2,S3,M)
S = {S1,S2,S3};

for i=1:3
    v = S{i};
    vi = v(M);

    if isempty(vi)
        vi = v(:);
    end

    p1 = prctile(vi,1);
    p99 = prctile(vi,99);

    v = min(max(v,p1), p99);

    mu = mean(v(M),'omitnan');
    if isnan(mu)
        mu = mean(v(:),'omitnan');
    end

    sd = std(v(M),1,'omitnan');
    if sd<=0 || isnan(sd)
        sd = std(v(:),1,'omitnan');
    end

    S{i} = (v - mu) / max(sd,1e-6);
end

S1 = S{1};
S2 = S{2};
S3 = S{3};
end


function y = sigmoid(x)
y = 1./(1+exp(-x));
end


function [S1,S2,S3] = synthSignals(PD,T1,T2,g1,g2,g3,ACQ)
% ACQ: (8,B) per-batch; here B=1. Broadcast over volume.
TRT1 = ACQ(1);
FAT1 = ACQ(3);
TRT2 = ACQ(4);
TET2 = ACQ(5);
TRF  = ACQ(6);
TEF  = ACQ(7);
TIF  = ACQ(8);

num = (1 - exp(-TRT1 ./ T1)) .* sin(FAT1);
den = 1 - cos(FAT1) .* exp(-TRT1 ./ T1);

S1  = g1 .* PD .* (num ./ (den + 1e-8));                         % T1w GRE, no T2*
S2  = g2 .* PD .* (1 - exp(-TRT2 ./ T1)) .* exp(-TET2 ./ T2);     % T2w SE
S3  = g3 .* PD .* (1 - 2*exp(-TIF ./ T1) + exp(-TRF ./ T1)) .* ...
    exp(-TEF ./ T2);                                            % FLAIR

S1(~isfinite(S1)) = 0;
S2(~isfinite(S2)) = 0;
S3(~isfinite(S3)) = 0;
end


function [PDp,T1p,T2p,g1p,g2p,g3p] = slidingPredict(net, X, ps, st, useGPU)
% X: [Z Y X C]; ps: [pz py px]; st: [sz sy sx]
% Returns raw network outputs before sigmoid: 6 channels.
assert(ndims(X)==4 && size(X,4)==3, 'X must be [Z Y X 3].');

% --- spatial sizes ---
Zdim = size(X,1);
Ydim = size(X,2);
Xdim = size(X,3);

% --- symmetric pad to fit complete patches ---
padZ = mod(-Zdim, ps(1));
padY = mod(-Ydim, ps(2));
padX = mod(-Xdim, ps(3));

Xpad = padarray(X, [padZ padY padX 0], 'symmetric', 'post');

Zp = size(Xpad,1);
Yp = size(Xpad,2);
Xp = size(Xpad,3);

% --- Gaussian blending window ---
try
    alpha = 3;
    wz = gausswin(ps(1), alpha);
    wy = gausswin(ps(2), alpha);
    wx = gausswin(ps(3), alpha);
catch
    sz = max(ps(1), 1);
    sy = max(ps(2), 1);
    sx = max(ps(3), 1);

    zc = (0:ps(1)-1) - (ps(1)-1)/2;
    yc = (0:ps(2)-1) - (ps(2)-1)/2;
    xc = (0:ps(3)-1) - (ps(3)-1)/2;

    wz = exp(-(zc.^2)/(2*sz^2)).';
    wy = exp(-(yc.^2)/(2*sy^2)).';
    wx = exp(-(xc.^2)/(2*sx^2)).';
end

win = reshape(wz, [ps(1) 1 1]) .* ...
    reshape(wy, [1 ps(2) 1]) .* ...
    reshape(wx, [1 1 ps(3)]);

win = single(win ./ max(win(:)));

% --- accumulators for weighted averaging ---
A = zeros(Zp, Yp, Xp, 6, 'single');  % weighted sum of outputs
W = zeros(Zp, Yp, Xp, 1, 'single');  % sum of weights

% --- iterate patches ---
for z = 1:st(1):Zp - ps(1) + 1
    for y = 1:st(2):Yp - ps(2) + 1
        for x = 1:st(3):Xp - ps(3) + 1

            patch = Xpad(z:z+ps(1)-1, ...
                y:y+ps(2)-1, ...
                x:x+ps(3)-1, :);  % [pz py px 3]

            dlX = dlarray(reshape(patch, [ps(1) ps(2) ps(3) 3 1]), 'SSSCB');

            if useGPU
                dlX = gpuArray(dlX);
            end

            Ypatch = predict(net, dlX);            % [pz py px 6 1]
            Ypatch = gather(extractdata(Ypatch));  % CPU array

            for c = 1:6
                A(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1, c) = ...
                    A(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1, c) + ...
                    Ypatch(:,:,:,c) .* win;
            end

            W(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1, 1) = ...
                W(z:z+ps(1)-1, y:y+ps(2)-1, x:x+ps(3)-1, 1) + win;

        end
    end
end

% --- normalize by sum of weights; crop to original size ---
epsW = single(1e-8);
Yfull = bsxfun(@rdivide, A, max(W, epsW));          % [Zp Yp Xp 6]
Yfull = Yfull(1:Zdim, 1:Ydim, 1:Xdim, :);           % crop

% --- split raw channels ---
PDp = Yfull(:,:,:,1);
T1p = Yfull(:,:,:,2);
T2p = Yfull(:,:,:,3);
g1p = Yfull(:,:,:,4);
g2p = Yfull(:,:,:,5);
g3p = Yfull(:,:,:,6);
end