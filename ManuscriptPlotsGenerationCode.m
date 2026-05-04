%% generate_results_package_qmri.m
% ================================================================
% Generate manuscript-ready FIGURES + TABLES for qMRI predictions
% from your saved folder structure:
%
% ProcessedData/
%   <PatientID>/
%     PREOP_T1_W_S.nii.gz
%     PREOP_AxT2_W_S.nii.gz
%     PREOP_FLAIR_W_S.nii.gz
%     pdmap.nii.gz
%     t1map.nii.gz
%     t2map.nii.gz
%     mask.nii.gz
%     P1L1OutPred/
%       PD_pred.nii.gz, T1_pred_ms.nii.gz, T2_pred_ms.nii.gz, ...
%     ...
%     P11L1OutPred/
%
% Assumption: Row order in acq_params.xlsx corresponds to patient index 1..N.
%            i.e., patient at row p has held-out folder "PpL1OutPred".
%
% Outputs:
%   - 5 Main figures (png + pdf)
%   - 3 Main tables (xlsx + csv)
%   - Suggested supplemental figures/tables (optional toggles)
%
% Requirements:
%   - Image Processing Toolbox recommended
%   - Statistics Toolbox for kmeans (optional ROI clustering)
%   - MATLAB can read .nii (niftiread). For .nii.gz we gunzip to temp.
% ================================================================

clear; clc; close all;

%% ---------------------- CONFIG ---------------------------------
% rootDir     = fullfile('/rsrch1/ip/mnandyala/Desktop/','hwang_cases','ProcessedData');
rootDir = pwd
excelName   = 'acq_params.xlsx';

% Raw / reference filenames in each patient folder
fname_T1w   = 'PREOP_T1_W_S.nii.gz';
fname_T2w   = 'PREOP_AxT2_W_S.nii.gz';
fname_FLAIR = 'PREOP_FLAIR_W_S.nii.gz';
fname_PDref = 'pdmap.nii.gz';
fname_T1ref = 't1map.nii.gz';
fname_T2ref = 't2map.nii.gz';
fname_mask  = 'mask.nii.gz';

% Predicted / calc names inside each PxL1OutPred folder
fname_PDpred    = 'PD_pred.nii.gz';
fname_T1pred    = 'T1_pred_ms.nii.gz';
fname_T2pred    = 'T2_pred_ms.nii.gz';
fname_g1pred    = 'g1_pred.nii.gz';
fname_g2pred    = 'g2_pred.nii.gz';
fname_g3pred    = 'g3_pred.nii.gz';
fname_T1w_calc  = 'T1w_calc.nii.gz';
fname_T2w_calc  = 'T2w_calc.nii.gz';
fname_FLAIR_calc= 'FLAIR_calc.nii.gz';

% Output directory
outDir = fullfile(rootDir, 'ManuscriptPlots');
if ~exist(outDir,'dir'), mkdir(outDir); end

% How many patients / folds
T = readtable(fullfile(rootDir, excelName), 'VariableNamingRule','preserve');
% Try to infer PatientID column
pidCol = find(strcmpi(T.Properties.VariableNames, 'PatientID'), 1);
if isempty(pidCol)
    % fallback: assume first column is PatientID
    pidCol = 1;
end
PatientID = string(T{:, pidCol});
PatientID = PatientID(~ismissing(PatientID));
N = numel(PatientID);

fprintf('[Info] Found %d patients from %s\n', N, excelName);

% Figure settings
savePNG = true; savePDF = false;saveFIG = true;
dpi = 300;

% Sampling for voxel-wise scatter/BA plots
maxVoxScatter = 30000000;  % total voxels to sample (across all patients)
rng(0);

% ROI-wise Bland-Altman mode:
%   'none'   -> voxel-wise BA (downsampled)
%   'kmeans' -> pseudo WM/GM/CSF by kmeans in (T1,T2) space from GT
roiMode = 'none';   % change to 'none' if you don’t want ROI clustering
kmeansK = 3;          % WM/GM/CSF
kmeansMaxVox = 30000000; % cap voxels used in clustering per patient

% Which subjects to show in qualitative figure:
%   'best_median_worst' based on held-out T1 MAE (you can change)
qualPickMode = 'best_median_worst';
nQualSubjects = 3;

% Supplemental toggles
makeSupplement_S2_signalConsistency = true;  % measured vs synthesized contrasts
makeSupplement_gainMaps             = true;  % g1/g2/g3 visualization
makeSupplement_foldTable            = true;  % fold-by-fold table
makeSupplement_tissueWiseTable      = true;  % WM/GM/CSF metrics if roiMode='kmeans'

%% ---------------------- PREALLOCATE ----------------------------
mapNames = ["PD","T1","T2"];
nMaps = numel(mapNames);

% Per patient (p), per fold (x), per map
MAE  = nan(N,N,nMaps);
RMSE = nan(N,N,nMaps);
NRMSE= nan(N,N,nMaps);
BIAS = nan(N,N,nMaps);
CCC  = nan(N,N,nMaps);

% Optional signal-consistency metrics (per contrast)
contrastNames = ["T1w","T2w","FLAIR"];
nC = numel(contrastNames);
MAE_sig  = nan(N,N,nC);
RMSE_sig = nan(N,N,nC);
CCC_sig  = nan(N,N,nC);

% Store a few volumes for ensemble std / example figures
Store = struct();
Store(N).pid = "";
for p=1:N
    Store(p).pid = PatientID(p);

    Store(p).mask = [];

    % GT maps
    Store(p).refPD = []; Store(p).refT1 = []; Store(p).refT2 = [];

    % Held-out predictions (x==p)
    Store(p).heldPD = []; Store(p).heldT1 = []; Store(p).heldT2 = [];

    % In-training ensemble stats (x~=p)
    Store(p).meanInPD = []; Store(p).meanInT1 = []; Store(p).meanInT2 = [];
    Store(p).stdInPD  = []; Store(p).stdInT1  = []; Store(p).stdInT2  = [];

    % Abs error maps for held-out
    Store(p).PDerror = []; Store(p).T1error = []; Store(p).T2error = [];

    % --- NEW: measured vs synthesized signals (held-out) ---
    Store(p).measT1w   = []; Store(p).measT2w   = []; Store(p).measFLAIR   = [];
    Store(p).calcT1w   = []; Store(p).calcT2w   = []; Store(p).calcFLAIR   = [];
    Store(p).T1Werror  = []; Store(p).T2Werror  = []; Store(p).FLAIRerror  = [];
end

% ROI masks if using kmeans
ROIs = cell(N,1);   % struct with fields .wm .gm .csf (logical)
ROI_labels = ["ROI1","ROI2","ROI3"]; % will reorder later by mean T1 if kmeans

%% ---------------------- MAIN LOOP ------------------------------
for p = 1:N
    pid = PatientID(p);
    pDir = fullfile(rootDir, pid);

    if ~exist(pDir,'dir')
        warning('[Skip] Missing patient folder: %s', pDir);
        continue;
    end

    % Load reference maps + mask
    mask = logical(load_nii_gz(fullfile(pDir, fname_mask)));
    refPD = single(load_nii_gz(fullfile(pDir, fname_PDref)));
    refT1 = single(load_nii_gz(fullfile(pDir, fname_T1ref)));
    refT2 = single(load_nii_gz(fullfile(pDir, fname_T2ref)));

    % Store
    Store(p).mask  = mask;
    Store(p).refPD = refPD; Store(p).refT1 = refT1; Store(p).refT2 = refT2;

    % Optional ROI construction
    if strcmpi(roiMode,'kmeans')
        ROIs{p} = make_kmeans_rois(refT1, refT2, mask, kmeansK, kmeansMaxVox);
    end

    % Loop folds (trained nets): x = 1..N
    predPD_allIn = []; predT1_allIn = []; predT2_allIn = []; % collect in-training preds for ensemble stats

    for x = 1:N
        foldDir = fullfile(pDir, sprintf('P%dL1OutPred', x));
        if ~exist(foldDir,'dir')
            warning('[Missing] %s', foldDir);
            continue;
        end

        predPD = single(load_nii_gz(fullfile(foldDir, fname_PDpred)));
        predT1 = single(load_nii_gz(fullfile(foldDir, fname_T1pred)));
        predT2 = single(load_nii_gz(fullfile(foldDir, fname_T2pred)));

        % Metrics vs GT within mask
        [MAE(p,x,1), RMSE(p,x,1), NRMSE(p,x,1), BIAS(p,x,1), CCC(p,x,1)] = ...
            compute_metrics(refPD, predPD, mask);

        [MAE(p,x,2), RMSE(p,x,2), NRMSE(p,x,2), BIAS(p,x,2), CCC(p,x,2)] = ...
            compute_metrics(refT1, predT1, mask);

        [MAE(p,x,3), RMSE(p,x,3), NRMSE(p,x,3), BIAS(p,x,3), CCC(p,x,3)] = ...
            compute_metrics(refT2, predT2, mask);

        % Signal-consistency (optional) if synthesized volumes exist
        if makeSupplement_S2_signalConsistency
            fCalc1 = fullfile(foldDir, fname_T1w_calc);
            fCalc2 = fullfile(foldDir, fname_T2w_calc);
            fCalc3 = fullfile(foldDir, fname_FLAIR_calc);
            if exist(fCalc1,'file') && exist(fCalc2,'file') && exist(fCalc3,'file')
                measT1w   = single(load_nii_gz(fullfile(pDir, fname_T1w)));
                measT2w   = single(load_nii_gz(fullfile(pDir, fname_T2w)));
                measFLAIR = single(load_nii_gz(fullfile(pDir, fname_FLAIR)));

                calcT1w   = single(load_nii_gz(fCalc1));
                calcT2w   = single(load_nii_gz(fCalc2));
                calcFLAIR = single(load_nii_gz(fCalc3));

                % ---- NEW: for held-out fold only, store measured/calc signals + abs error maps ----
                if x == p
                    Store(p).measT1w   = measT1w;
                    Store(p).measT2w   = measT2w;
                    Store(p).measFLAIR = measFLAIR;

                    Store(p).calcT1w   = calcT1w;
                    Store(p).calcT2w   = calcT2w;
                    Store(p).calcFLAIR = calcFLAIR;

                    Store(p).T1Werror   = abs(calcT1w   - measT1w);
                    Store(p).T2Werror   = abs(calcT2w   - measT2w);
                    Store(p).FLAIRerror = abs(calcFLAIR - measFLAIR);

                    % ---- write signal error volumes to held-out folder as .nii.gz ----
                    infoT1w = niftiinfo_gz(fullfile(pDir, fname_T1w));
                    infoT2w = niftiinfo_gz(fullfile(pDir, fname_T2w));
                    infoFL  = niftiinfo_gz(fullfile(pDir, fname_FLAIR));

                    write_nii_gz(Store(p).T1Werror,   infoT1w, fullfile(foldDir, "T1Werror.nii.gz"));
                    write_nii_gz(Store(p).T2Werror,   infoT2w, fullfile(foldDir, "T2Werror.nii.gz"));
                    write_nii_gz(Store(p).FLAIRerror, infoFL,  fullfile(foldDir, "FLAIRerror.nii.gz"));
                end
                [MAE_sig(p,x,1), RMSE_sig(p,x,1), ~, ~, CCC_sig(p,x,1)] = compute_metrics(measT1w, calcT1w, mask);
                [MAE_sig(p,x,2), RMSE_sig(p,x,2), ~, ~, CCC_sig(p,x,2)] = compute_metrics(measT2w, calcT2w, mask);
                [MAE_sig(p,x,3), RMSE_sig(p,x,3), ~, ~, CCC_sig(p,x,3)] = compute_metrics(measFLAIR, calcFLAIR, mask);
            end
        end

        % Collect in-training predictions for ensemble stats (x ~= p)
        if x ~= p
            predPD_allIn = cat(4, predPD_allIn, predPD);
            predT1_allIn = cat(4, predT1_allIn, predT1);
            predT2_allIn = cat(4, predT2_allIn, predT2);
        end

        % Save held-out volumes (x == p)
        if x == p
            Store(p).heldPD = predPD;
            Store(p).heldT1 = predT1;
            Store(p).heldT2 = predT2;

            % Absolute error maps (GT vs held-out pred)
            Store(p).PDerror = abs(predPD - refPD);
            Store(p).T1error = abs(predT1 - refT1);
            Store(p).T2error = abs(predT2 - refT2);

            % ---- NEW: write qmap error volumes to held-out folder as .nii.gz ----
            % Use GT NIfTI header as reference geometry
            infoPD = niftiinfo_gz(fullfile(pDir, fname_PDref));
            infoT1 = niftiinfo_gz(fullfile(pDir, fname_T1ref));
            infoT2 = niftiinfo_gz(fullfile(pDir, fname_T2ref));

            write_nii_gz(Store(p).PDerror, infoPD, fullfile(foldDir, "PDerror.nii.gz"));
            write_nii_gz(Store(p).T1error, infoT1, fullfile(foldDir, "T1error.nii.gz"));
            write_nii_gz(Store(p).T2error, infoT2, fullfile(foldDir, "T2error.nii.gz"));
        end
    end

    % In-training ensemble mean/std (across 10 folds)
    if ~isempty(predPD_allIn)
        Store(p).meanInPD = mean(predPD_allIn, 4, 'omitnan');
        Store(p).meanInT1 = mean(predT1_allIn, 4, 'omitnan');
        Store(p).meanInT2 = mean(predT2_allIn, 4, 'omitnan');

        Store(p).stdInPD  = std(predPD_allIn, 0, 4, 'omitnan');
        Store(p).stdInT1  = std(predT1_allIn, 0, 4, 'omitnan');
        Store(p).stdInT2  = std(predT2_allIn, 0, 4, 'omitnan');
    end

    fprintf('[Done] %s (%d/%d)\n', pid, p, N);
end

%% ---------------------- DERIVED METRICS ------------------------
% Held-out metrics per patient: x = p
held_MAE  = squeeze(diag3(MAE));
held_RMSE = squeeze(diag3(RMSE));
held_NRMSE= squeeze(diag3(NRMSE));
held_BIAS = squeeze(diag3(BIAS));
held_CCC  = squeeze(diag3(CCC));

% In-training metrics per patient: mean over x ~= p
in_MAE  = nan(N,nMaps);
in_RMSE = nan(N,nMaps);
in_CCC  = nan(N,nMaps);
in_BIAS = nan(N,nMaps);
for p=1:N
    idx = setdiff(1:N, p);
    in_MAE(p,:)  = squeeze(mean(MAE(p,idx,:), 2, 'omitnan'));
    in_RMSE(p,:) = squeeze(mean(RMSE(p,idx,:),2, 'omitnan'));
    in_CCC(p,:)  = squeeze(mean(CCC(p,idx,:), 2, 'omitnan'));
    in_BIAS(p,:) = squeeze(mean(BIAS(p,idx,:),2, 'omitnan'));
end

gap_MAE = held_MAE - in_MAE;
gap_CCC = held_CCC - in_CCC;

%% ---------------------- TABLE 1: Overall Held-out ---------------
Table1 = table(mapNames', ...
    mean(held_MAE,1,'omitnan')',  std(held_MAE,0,1,'omitnan')', ...
    mean(held_RMSE,1,'omitnan')', std(held_RMSE,0,1,'omitnan')', ...
    mean(held_CCC,1,'omitnan')',  std(held_CCC,0,1,'omitnan')', ...
    mean(held_BIAS,1,'omitnan')', std(held_BIAS,0,1,'omitnan')', ...
    'VariableNames', {'Map','MAE_mean','MAE_std','RMSE_mean','RMSE_std','CCC_mean','CCC_std','Bias_mean','Bias_std'});

writetable(Table1, fullfile(outDir,'Table1_OverallHeldOut.xlsx'));
writetable(Table1, fullfile(outDir,'Table1_OverallHeldOut.csv'));
disp(Table1);

%% ---------------------- TABLE 2: Included vs Excluded ----------
Table2 = table(mapNames', ...
    mean(held_MAE,1,'omitnan')', mean(in_MAE,1,'omitnan')', mean(gap_MAE,1,'omitnan')', ...
    mean(held_CCC,1,'omitnan')', mean(in_CCC,1,'omitnan')', mean(gap_CCC,1,'omitnan')', ...
    'VariableNames', {'Map','HeldOut_MAE','InTrainMean_MAE','Gap_MAE','HeldOut_CCC','InTrainMean_CCC','Gap_CCC'});

% Optional paired test on MAE gap (Wilcoxon)
pvals = nan(nMaps,1);
for m=1:nMaps
    a = held_MAE(:,m); b = in_MAE(:,m);
    if all(isnan(a)) || all(isnan(b)), continue; end
    try
        pvals(m) = signrank(a, b); % paired
    catch
        pvals(m) = NaN;
    end
end
Table2.pValue_signrank_MAE = pvals;

writetable(Table2, fullfile(outDir,'Table2_InTrain_vs_HeldOut.xlsx'));
writetable(Table2, fullfile(outDir,'Table2_InTrain_vs_HeldOut.csv'));
disp(Table2);

%% ---------------------- TABLE 3: Subject-level summary ----------
Table3 = table(PatientID(:), ...
    held_MAE(:,1), held_MAE(:,2), held_MAE(:,3), ...
    in_MAE(:,1),   in_MAE(:,2),   in_MAE(:,3), ...
    gap_MAE(:,1),  gap_MAE(:,2),  gap_MAE(:,3), ...
    held_CCC(:,1), held_CCC(:,2), held_CCC(:,3), ...
    'VariableNames', {'PatientID', ...
    'Held_MAE_PD','Held_MAE_T1','Held_MAE_T2', ...
    'InTrainMean_MAE_PD','InTrainMean_MAE_T1','InTrainMean_MAE_T2', ...
    'Gap_MAE_PD','Gap_MAE_T1','Gap_MAE_T2', ...
    'Held_CCC_PD','Held_CCC_T1','Held_CCC_T2'});

writetable(Table3, fullfile(outDir,'Table3_SubjectLevel.xlsx'));
writetable(Table3, fullfile(outDir,'Table3_SubjectLevel.csv'));
disp(Table3(1:min(5,height(Table3)),:));

%% =====FIGURE 1 — Qualitative maps: GT vs Held-out vs |Error|for each patient =======
% FIGURE 1 — Qualitative maps: GT vs Held-out vs |Error|
% - DEFAULT spacing (no manual position edits)
% - SAME colormap for all 3 panels (gray or user-specified)
% - GT+Pred share SAME caxis and ONE colorbar (per row)
% - Error has its OWN caxis and ONE colorbar (per row)
% ================================================================

% Choose ONE colormap for the whole figure
useGray = true;           % set false to use custom cmap below
cmap = gray(256);         % grayscale
% cmap = parula(256);     % example alternative

% Choose subjects
switch lower(qualPickMode)
    case 'best_median_worst'
        [~,ord] = sort(held_MAE(:,2),'ascend'); % use T1 held-out MAE
        pick = unique([ord(1), ord(round(N/2)), ord(end)]);
    otherwise
        pick = 1:min(nQualSubjects,N);
end
% pick = pick(1:min(numel(pick)));%, nQualSubjects));

pick = [1:11];

for ii = 1:numel(pick)

    p    = pick(ii);
    mask = Store(p).mask;

    refs = {Store(p).refPD,  Store(p).refT1,  Store(p).refT2};
    held = {Store(p).heldPD, Store(p).heldT1, Store(p).heldT2};
    errs = {Store(p).PDerror, Store(p).T1error, Store(p).T2error};
    % if ~isempty(mask)
    %     z = choose_best_slice(mask);   % best axial slice by mask area
    % else
    %     z = [];                        % fallback later
    % end
    z = ceil(size(mask,3)/2);
    close all
    f1 = figure('Color','w','Name',sprintf('Fig1_Qualitative_%s',Store(p).pid));
    tiledlayout(3,3,'Padding','compact','TileSpacing','compact'); % DEFAULT-ish

    for m = 1:3   % PD, T1, T2

        R = refs{m};
        H = held{m};
        E = errs{m};

        if isempty(R) || isempty(H)
            for kk=1:3, nexttile; axis off; end
            continue;
        end

        if isempty(z)
            zUse = ceil(size(R,3)/2);
        else
            zUse = max(1, min(z, size(R,3)));
        end

        Rs = R(:,:,zUse);
        Hs = H(:,:,zUse);
        Es = E(:,:,zUse);
        if ~isempty(mask)
            ms = mask(:,:,zUse);
        else
            ms = true(size(Rs));
        end

        % -------------------------------
        % SCALE FOR GT + PRED (from GT only)
        % -------------------------------
        v = double(Rs(ms));
        v = v(isfinite(v));
        if isempty(v)
            lo = 0; hi = 1;
        else
            lo = prctile(v,2);
            hi = prctile(v,98);
            if lo == hi
                lo = min(v); hi = max(v);
                if lo == hi, lo = lo-1; hi = hi+1; end
            end
        end

        % -------------------------------
        % ERROR SCALE (abs error)
        % -------------------------------

        ev = double(Es(ms));
        ev = ev(isfinite(ev));
        if isempty(ev)
            elo = 0; ehi = 1;
        else
            elo = 0;
            ehi = prctile(ev,98);
            if ~isfinite(ehi) || ehi <= 0
                ehi = max(ev);
                if ~isfinite(ehi) || ehi <= 0, ehi = 1; end
            end
        end

        % --------------------------------
        % Plot row (GT / Pred / Error)
        % --------------------------------

        Rs_plot = rot90(Rs,3);   % rotate 90° counterclockwise
        Hs_plot = rot90(Hs,3);
        Es_plot = rot90(Es,3);

        axGT = nexttile;
        imagesc(axGT, Rs_plot); axis(axGT,'image'); axis(axGT,'off');
        caxis(axGT,[lo hi]);

        axPR = nexttile;
        imagesc(axPR, Hs_plot); axis(axPR,'image'); axis(axPR,'off');
        caxis(axPR,[lo hi]);

        axER = nexttile;
        imagesc(axER, Es_plot); axis(axER,'image'); axis(axER,'off');
        caxis(axER,[elo ehi]);

        % Titles / labels
        if m == 1
            title(axGT,'Ground Truth','FontWeight','normal');
            title(axPR,'Prediction','FontWeight','normal');
            title(axER,'|Error|','FontWeight','normal');
        end
        ylabel(axGT, mapNames(m), 'Interpreter','none');

        % Same colormap on all axes
        if useGray
            colormap(axGT, gray(256));
            colormap(axPR, gray(256));
            colormap(axER, gray(256));
        else
            colormap(axGT, cmap);
            colormap(axPR, cmap);
            colormap(axER, cmap);
        end

        % --------------------------------
        % Colorbars (DEFAULT placement)
        % - ONE shared bar for GT+Pred: attach to Prediction axis
        % - ONE bar for Error: attach to Error axis
        % --------------------------------
        cbMap = colorbar(axPR, 'eastoutside');
        cbMap.Label.String = char(mapNames(m));

        cbErr = colorbar(axER, 'eastoutside');
        cbErr.Label.String = ['|Error| ' char(mapNames(m))];
    end

    set(findall(f1,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(f1,'-property','FontSize'), 'FontSize', 14);
    %
    save_figure(f1, outDir, sprintf('Figure1A_Qualitative_%s_QmapsBW',Store(p).pid), ...
        savePNG, savePDF, saveFIG, dpi);
end
% Choose ONE colormap for the whole figure
useGray = false;           % set false to use custom cmap below
% cmap = gray(256);         % grayscale
cmap = parula(256);     % example alternative

% Choose subjects
switch lower(qualPickMode)
    case 'best_median_worst'
        [~,ord] = sort(held_MAE(:,2),'ascend'); % use T1 held-out MAE
        pick = unique([ord(1), ord(round(N/2)), ord(end)]);
    otherwise
        pick = 1:min(nQualSubjects,N);
end
% pick = pick(1:min(numel(pick)));%, nQualSubjects));

pick = [1:11];

for ii = 1:numel(pick)

    p    = pick(ii);
    mask = Store(p).mask;

    refs = {Store(p).refPD,  Store(p).refT1,  Store(p).refT2};
    held = {Store(p).heldPD, Store(p).heldT1, Store(p).heldT2};
    errs = {Store(p).PDerror, Store(p).T1error, Store(p).T2error};
    % if ~isempty(mask)
    %     z = choose_best_slice(mask);   % best axial slice by mask area
    % else
    %     z = [];                        % fallback later
    % end
    z = ceil(size(mask,3)/2);
    close all
    f1 = figure('Color','w','Name',sprintf('Fig1_Qualitative_%s',Store(p).pid));
    tiledlayout(3,3,'Padding','compact','TileSpacing','compact'); % DEFAULT-ish

    for m = 1:3   % PD, T1, T2

        R = refs{m};
        H = held{m};
        E = errs{m};

        if isempty(R) || isempty(H)
            for kk=1:3, nexttile; axis off; end
            continue;
        end

        if isempty(z)
            zUse = ceil(size(R,3)/2);
        else
            zUse = max(1, min(z, size(R,3)));
        end

        Rs = R(:,:,zUse);
        Hs = H(:,:,zUse);
        Es = E(:,:,zUse);
        if ~isempty(mask)
            ms = mask(:,:,zUse);
        else
            ms = true(size(Rs));
        end

        % -------------------------------
        % SCALE FOR GT + PRED (from GT only)
        % -------------------------------
        v = double(Rs(ms));
        v = v(isfinite(v));
        if isempty(v)
            lo = 0; hi = 1;
        else
            lo = prctile(v,2);
            hi = prctile(v,98);
            if lo == hi
                lo = min(v); hi = max(v);
                if lo == hi, lo = lo-1; hi = hi+1; end
            end
        end

        % -------------------------------
        % ERROR SCALE (abs error)
        % -------------------------------

        ev = double(Es(ms));
        ev = ev(isfinite(ev));
        if isempty(ev)
            elo = 0; ehi = 1;
        else
            elo = 0;
            ehi = prctile(ev,98);
            if ~isfinite(ehi) || ehi <= 0
                ehi = max(ev);
                if ~isfinite(ehi) || ehi <= 0, ehi = 1; end
            end
        end

        % --------------------------------
        % Plot row (GT / Pred / Error)
        % --------------------------------

        Rs_plot = rot90(Rs,3);   % rotate 90° counterclockwise
        Hs_plot = rot90(Hs,3);
        Es_plot = rot90(Es,3);

        axGT = nexttile;
        imagesc(axGT, Rs_plot); axis(axGT,'image'); axis(axGT,'off');
        caxis(axGT,[lo hi]);

        axPR = nexttile;
        imagesc(axPR, Hs_plot); axis(axPR,'image'); axis(axPR,'off');
        caxis(axPR,[lo hi]);

        axER = nexttile;
        imagesc(axER, Es_plot); axis(axER,'image'); axis(axER,'off');
        caxis(axER,[elo ehi]);

        % Titles / labels
        if m == 1
            title(axGT,'Ground Truth','FontWeight','normal');
            title(axPR,'Prediction','FontWeight','normal');
            title(axER,'|Error|','FontWeight','normal');
        end
        ylabel(axGT, mapNames(m), 'Interpreter','none');

        % Same colormap on all axes
        if useGray
            colormap(axGT, gray(256));
            colormap(axPR, gray(256));
            colormap(axER, gray(256));
        else
            colormap(axGT, cmap);
            colormap(axPR, cmap);
            colormap(axER, cmap);
        end

        % --------------------------------
        % Colorbars (DEFAULT placement)
        % - ONE shared bar for GT+Pred: attach to Prediction axis
        % - ONE bar for Error: attach to Error axis
        % --------------------------------
        cbMap = colorbar(axPR, 'eastoutside');
        cbMap.Label.String = char(mapNames(m));

        cbErr = colorbar(axER, 'eastoutside');
        cbErr.Label.String = ['|Error| ' char(mapNames(m))];
    end

    set(findall(f1,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(f1,'-property','FontSize'), 'FontSize', 14);

    save_figure(f1, outDir, sprintf('Figure1A_Qualitative_%s_QmapsCLR',Store(p).pid), ...
        savePNG, savePDF, saveFIG, dpi);
end

%%% ================================================================
% Figure 1B Acuqired and calculated signals and the errors
% ================================================================

% Choose ONE colormap for the whole figure
useGray = true;           % set false to use custom cmap below
cmap = gray(256);         % grayscale
% cmap = parula(256);     % example alternative

% Choose subjects
switch lower(qualPickMode)
    case 'best_median_worst'
        [~,ord] = sort(held_MAE(:,2),'ascend'); % use T1 held-out MAE
        pick = unique([ord(1), ord(round(N/2)), ord(end)]);
    otherwise
        pick = 1:min(nQualSubjects,N);
end
% pick = pick(1:min(numel(pick)));%, nQualSubjects));

pick = [1:11];
sigNames = ["T1W", "T2W", "FLAIR"];
for ii = 1:numel(pick)

    p    = pick(ii);
    mask = Store(p).mask;

    refs = {Store(p).measT1w,  Store(p).measT2w,  Store(p).measFLAIR};
    held = {Store(p).calcT1w,  Store(p).calcT2w,  Store(p).calcFLAIR};%{Store(p).heldPD, Store(p).heldT1, Store(p).heldT2};
    errs = {Store(p).T1Werror, Store(p).T2Werror, Store(p).FLAIRerror};
    % if ~isempty(mask)
    %     z = choose_best_slice(mask);   % best axial slice by mask area
    % else
    %     z = [];                        % fallback later
    % end
    z = ceil(size(mask,3)/2);
    close all
    f1 = figure('Color','w','Name',sprintf('Fig1_Qualitative_%s',Store(p).pid));
    tiledlayout(3,3,'Padding','compact','TileSpacing','compact'); % DEFAULT-ish

    for m = 1:3   % PD, T1, T2

        R = refs{m};
        H = held{m};
        E = errs{m};

        if isempty(R) || isempty(H)
            for kk=1:3, nexttile; axis off; end
            continue;
        end

        if isempty(z)
            zUse = ceil(size(R,3)/2);
        else
            zUse = max(1, min(z, size(R,3)));
        end

        Rs = R(:,:,zUse);
        Hs = H(:,:,zUse);
        Es = E(:,:,zUse);
        if ~isempty(mask)
            ms = mask(:,:,zUse);
        else
            ms = true(size(Rs));
        end

        % -------------------------------
        % SCALE FOR GT + PRED (from GT only)
        % -------------------------------
        v = double(Rs(ms));
        v = v(isfinite(v));
        if isempty(v)
            lo = 0; hi = 1;
        else
            lo = prctile(v,2);
            hi = prctile(v,98);
            if lo == hi
                lo = min(v); hi = max(v);
                if lo == hi, lo = lo-1; hi = hi+1; end
            end
        end

        % -------------------------------
        % ERROR SCALE (abs error)
        % -------------------------------

        ev = double(Es(ms));
        ev = ev(isfinite(ev));
        if isempty(ev)
            elo = 0; ehi = 1;
        else
            elo = 0;
            ehi = prctile(ev,98);
            if ~isfinite(ehi) || ehi <= 0
                ehi = max(ev);
                if ~isfinite(ehi) || ehi <= 0, ehi = 1; end
            end
        end

        % --------------------------------
        % Plot row (GT / Pred / Error)
        % --------------------------------

        Rs_plot = rot90(Rs,3);   % rotate 90° counterclockwise
        Hs_plot = rot90(Hs,3);
        Es_plot = rot90(Es,3);

        axGT = nexttile;
        imagesc(axGT, Rs_plot); axis(axGT,'image'); axis(axGT,'off');
        caxis(axGT,[lo hi]);

        axPR = nexttile;
        imagesc(axPR, Hs_plot); axis(axPR,'image'); axis(axPR,'off');
        caxis(axPR,[lo hi]);

        axER = nexttile;
        imagesc(axER, Es_plot); axis(axER,'image'); axis(axER,'off');
        caxis(axER,[elo ehi]);

        % Titles / labels
        if m == 1
            title(axGT,'Acquired','FontWeight','normal');
            title(axPR,'Calculated','FontWeight','normal');
            title(axER,'|Error|','FontWeight','normal');
        end
        ylabel(axGT, sigNames(m), 'Interpreter','none');

        % Same colormap on all axes
        if useGray
            colormap(axGT, gray(256));
            colormap(axPR, gray(256));
            colormap(axER, gray(256));
        else
            colormap(axGT, cmap);
            colormap(axPR, cmap);
            colormap(axER, cmap);
        end

        % --------------------------------
        % Colorbars (DEFAULT placement)
        % - ONE shared bar for GT+Pred: attach to Prediction axis
        % - ONE bar for Error: attach to Error axis
        % --------------------------------
        cbMap = colorbar(axPR, 'eastoutside');
        cbMap.Label.String = char(sigNames(m));

        cbErr = colorbar(axER, 'eastoutside');
        cbErr.Label.String = ['|Error| ' char(sigNames(m))];
    end

    set(findall(f1,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(f1,'-property','FontSize'), 'FontSize', 14);

    save_figure(f1, outDir, sprintf('Figure1B_Qualitative_%s_SigBW',Store(p).pid), ...
        savePNG, savePDF, saveFIG, dpi);
end



% Choose ONE colormap for the whole figure
useGray = false;           % set false to use custom cmap below
% cmap = gray(256);         % grayscale
cmap = parula(256);     % example alternative

% Choose subjects
switch lower(qualPickMode)
    case 'best_median_worst'
        [~,ord] = sort(held_MAE(:,2),'ascend'); % use T1 held-out MAE
        pick = unique([ord(1), ord(round(N/2)), ord(end)]);
    otherwise
        pick = 1:min(nQualSubjects,N);
end
% pick = pick(1:min(numel(pick)));%, nQualSubjects));

pick = [1:11];
sigNames = ["T1W", "T2W", "FLAIR"];
for ii = 1:numel(pick)

    p    = pick(ii);
    mask = Store(p).mask;

    refs = {Store(p).measT1w,  Store(p).measT2w,  Store(p).measFLAIR};
    held = {Store(p).calcT1w,  Store(p).calcT2w,  Store(p).calcFLAIR};%{Store(p).heldPD, Store(p).heldT1, Store(p).heldT2};
    errs = {Store(p).T1Werror, Store(p).T2Werror, Store(p).FLAIRerror};
    % if ~isempty(mask)
    %     z = choose_best_slice(mask);   % best axial slice by mask area
    % else
    %     z = [];                        % fallback later
    % end
    z = ceil(size(mask,3)/2);
    close all
    f1 = figure('Color','w','Name',sprintf('Fig1_Qualitative_%s',Store(p).pid));
    tiledlayout(3,3,'Padding','compact','TileSpacing','compact'); % DEFAULT-ish

    for m = 1:3   % PD, T1, T2

        R = refs{m};
        H = held{m};
        E = errs{m};

        if isempty(R) || isempty(H)
            for kk=1:3, nexttile; axis off; end
            continue;
        end

        if isempty(z)
            zUse = ceil(size(R,3)/2);
        else
            zUse = max(1, min(z, size(R,3)));
        end

        Rs = R(:,:,zUse);
        Hs = H(:,:,zUse);
        Es = E(:,:,zUse);
        if ~isempty(mask)
            ms = mask(:,:,zUse);
        else
            ms = true(size(Rs));
        end

        % -------------------------------
        % SCALE FOR GT + PRED (from GT only)
        % -------------------------------
        v = double(Rs(ms));
        v = v(isfinite(v));
        if isempty(v)
            lo = 0; hi = 1;
        else
            lo = prctile(v,2);
            hi = prctile(v,98);
            if lo == hi
                lo = min(v); hi = max(v);
                if lo == hi, lo = lo-1; hi = hi+1; end
            end
        end

        % -------------------------------
        % ERROR SCALE (abs error)
        % -------------------------------

        ev = double(Es(ms));
        ev = ev(isfinite(ev));
        if isempty(ev)
            elo = 0; ehi = 1;
        else
            elo = 0;
            ehi = prctile(ev,98);
            if ~isfinite(ehi) || ehi <= 0
                ehi = max(ev);
                if ~isfinite(ehi) || ehi <= 0, ehi = 1; end
            end
        end

        % --------------------------------
        % Plot row (GT / Pred / Error)
        % --------------------------------


        Rs_plot = rot90(Rs,3);   % rotate 90° counterclockwise
        Hs_plot = rot90(Hs,3);
        Es_plot = rot90(Es,3);

        axGT = nexttile;
        imagesc(axGT, Rs_plot); axis(axGT,'image'); axis(axGT,'off');
        caxis(axGT,[lo hi]);

        axPR = nexttile;
        imagesc(axPR, Hs_plot); axis(axPR,'image'); axis(axPR,'off');
        caxis(axPR,[lo hi]);

        axER = nexttile;
        imagesc(axER, Es_plot); axis(axER,'image'); axis(axER,'off');
        caxis(axER,[elo ehi]);

        % Titles / labels
        if m == 1
            title(axGT,'Acquired','FontWeight','normal');
            title(axPR,'Calculated','FontWeight','normal');
            title(axER,'|Error|','FontWeight','normal');
        end
        ylabel(axGT, sigNames(m), 'Interpreter','none');

        % Same colormap on all axes
        if useGray
            colormap(axGT, gray(256));
            colormap(axPR, gray(256));
            colormap(axER, gray(256));
        else
            colormap(axGT, cmap);
            colormap(axPR, cmap);
            colormap(axER, cmap);
        end

        % --------------------------------
        % Colorbars (DEFAULT placement)
        % - ONE shared bar for GT+Pred: attach to Prediction axis
        % - ONE bar for Error: attach to Error axis
        % --------------------------------
        cbMap = colorbar(axPR, 'eastoutside');
        cbMap.Label.String = char(sigNames(m));

        cbErr = colorbar(axER, 'eastoutside');
        cbErr.Label.String = ['|Error| ' char(sigNames(m))];
    end

    set(findall(f1,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(f1,'-property','FontSize'), 'FontSize', 14);

    save_figure(f1, outDir, sprintf('Figure1B_Qualitative_%s_SigCLR',Store(p).pid), ...
        savePNG, savePDF, saveFIG, dpi);
end
%% ======================Histogram Plots for each patient==========================================%%
% FIGURE — Filled histogram comparison of full 3D volume within brain mask
% Top row    : qmaps   -> PD, T1, T2
% Bottom row : signals -> T1W, T2W, FLAIR
% - Common bins for GT and Prediction within each tile
% - Histogram x-limits are the chosen data range
% - Same range is also used for the bins
% - Filled histograms with transparency
% - Uses frequency/count
% - Hides y-axis ticks but keeps box
% ================================================================


pick = 1:11;

showLegend = true;

% ------------------------------------------------
% RANGE CONTROL
% ------------------------------------------------
usePercentileRange = false;   % true = use percentile-trimmed range
rangePrct = [0.5 99.5];       % percentile range for display + bins

for ii = 1:numel(pick)

    p = pick(ii);

    mask = Store(p).mask;
    if isempty(mask)
        fprintf('[Skip] Missing mask for patient %s\n', Store(p).pid);
        continue;
    end

    % ---------------------------
    % Top row: qmaps
    % ---------------------------
    refs_q   = {Store(p).refPD,   Store(p).refT1,   Store(p).refT2};
    held_q   = {Store(p).heldPD,  Store(p).heldT1,  Store(p).heldT2};
    names_q  = {'PD','T1','T2'};

    % ---------------------------
    % Bottom row: signals
    % ---------------------------
    refs_s   = {Store(p).measT1w,   Store(p).measT2w,   Store(p).measFLAIR};
    held_s   = {Store(p).calcT1w,   Store(p).calcT2w,   Store(p).calcFLAIR};
    names_s  = {'T1W','T2W','FLAIR'};

    close all
    fH = figure('Color','w', ...
        'Name', sprintf('Fig_Hist_%s', Store(p).pid), ...
        'Units','pixels');

    tiledlayout(2,3,'Padding','compact','TileSpacing','compact');

    % ============================================================
    % LOOP OVER 6 PANELS
    % ============================================================
    for m = 1:6

        if m <= 3
            R = refs_q{m};
            H = held_q{m};
            xlab = names_q{m};
        else
            kk = m - 3;
            R = refs_s{kk};
            H = held_s{kk};
            xlab = names_s{kk};
        end

        ax = nexttile;
        hold(ax,'on');

        if isempty(R) || isempty(H)
            text(ax, 0.5, 0.5, 'Missing data', 'HorizontalAlignment','center');
            axis(ax,'off');
            continue;
        end

        % Full 3D masked voxels
        idx = mask & isfinite(R) & isfinite(H);
        rVals = double(R(idx));
        hVals = double(H(idx));

        if isempty(rVals) || isempty(hVals)
            text(ax, 0.5, 0.5, 'No valid voxels', 'HorizontalAlignment','center');
            axis(ax,'off');
            continue;
        end

        % Combined values
        allVals = [rVals; hVals];
        allVals = allVals(isfinite(allVals));

        % ------------------------------------------------------------
        % X-AXIS RANGE from combined GT + Prediction
        % Same range will also be used for histogram bins
        % ------------------------------------------------------------
        if usePercentileRange
            xmin = prctile(allVals, rangePrct(1));
            xmax = prctile(allVals, rangePrct(2));
        else
            xmin = min(allVals);
            xmax = max(allVals);
        end

        if ~isfinite(xmin) || ~isfinite(xmax) || xmin == xmax
            xmin = min(allVals);
            xmax = max(allVals);
            if ~isfinite(xmin) || ~isfinite(xmax) || xmin == xmax
                xmin = xmin - 1;
                xmax = xmax + 1;
            end
        end

        % ------------------------------------------------------------
        % Clip displayed histogram data to chosen range
        % ------------------------------------------------------------
        rValsPlot = rVals(rVals >= xmin & rVals <= xmax);
        hValsPlot = hVals(hVals >= xmin & hVals <= xmax);

        if isempty(rValsPlot) || isempty(hValsPlot)
            text(ax, 0.5, 0.5, 'No voxels in selected range', ...
                'HorizontalAlignment','center');
            axis(ax,'off');
            continue;
        end

        % ------------------------------------------------------------
        % Common bins using the SAME chosen range
        % Freedman–Diaconis bin width from combined clipped data
        % ------------------------------------------------------------
        allValsPlot = [rValsPlot; hValsPlot];
        nAll = numel(allValsPlot);

        q75 = prctile(allValsPlot, 75);
        q25 = prctile(allValsPlot, 25);
        iqrVal = q75 - q25;

        if iqrVal > 0
            binWidth = 2 * iqrVal * nAll^(-1/3);
        else
            binWidth = (xmax - xmin) / 100;
        end

        if ~isfinite(binWidth) || binWidth <= 0
            binWidth = (xmax - xmin) / 100;
        end

        nBins = ceil((xmax - xmin) / binWidth);
        nBins = max(nBins, 30);
        nBins = min(nBins, 100);

        % SAME edges for GT and Prediction
        edges = linspace(xmin, xmax, nBins + 1);

        % ------------------------------------------------------------
        % Filled histograms with transparency
        % Uses frequency/count
        % ------------------------------------------------------------
        hGT = histogram(ax, rValsPlot, edges, ...
            'Normalization', 'count', ...
            'DisplayStyle', 'bar', ...
            'FaceAlpha', 0.45, ...
            'EdgeAlpha', 0.25, ...
            'LineWidth', 0.5);

        hPR = histogram(ax, hValsPlot, edges, ...
            'Normalization', 'count', ...
            'DisplayStyle', 'bar', ...
            'FaceAlpha', 0.45, ...
            'EdgeAlpha', 0.25, ...
            'LineWidth', 0.5);

        % Colors
        hGT.FaceColor = [0 0.4470 0.7410];
        hGT.EdgeColor = [0 0.4470 0.7410];

        hPR.FaceColor = [0.8500 0.3250 0.0980];
        hPR.EdgeColor = [0.8500 0.3250 0.0980];

        xlim(ax, [xmin xmax]);

        % Keep box, hide y tick labels
        box(ax,'on');
        ax.LineWidth = 0.5;
        ax.XColor = 'k';
        ax.YColor = 'k';
        ax.YTick = [];
        ylabel(ax, '');

        pbaspect(ax,[1.5 1 1]);

        xlabel(ax, xlab);

        % Put legend once in the middle top tile (T1)
        if showLegend && m == 2
            lgd = legend(ax, {'Ground Truth','Prediction'}, 'Location','northoutside');
            lgd.Box = 'off';
            lgd.NumColumns = 2;
            lgd.Orientation = 'horizontal';
        end

        % Put legend once in the middle top tile (T1)
        if showLegend && m == 5
            lgd = legend(ax, {'Acquired','Calculated'}, 'Location','northoutside');
            lgd.Box = 'off';
            lgd.NumColumns = 2;
            lgd.Orientation = 'horizontal';
        end
    end

    set(findall(fH,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(fH,'-property','FontSize'), 'FontSize', 14);

    save_figure(fH, outDir, sprintf('Figure_Histogram_%s_QmapsSignals', Store(p).pid), ...
        savePNG, savePDF, saveFIG, dpi);
end

%% ============================Scatter plot for each patient====================================
% FIGURE 21 — Voxel-wise agreement scatter (Held-out vs GT) (density)
% ================================================================
% All voxel for each patient
for i = 1:numel(pick)
    selectpatient = i;
    sp = Store(selectpatient);
    mask = sp.mask;
    maskedvox = find(mask);
    Xpd = sp.refPD(maskedvox);
    Ypd = sp.heldPD(maskedvox);
    cccpd = concordance_cc(Xpd, Ypd);

    Xt1 = sp.refT1(maskedvox);
    Yt1 = sp.heldT1(maskedvox);
    ccct1 = concordance_cc(Xt1, Yt1);

    Xt2 = sp.refT2(maskedvox);
    Yt2 = sp.heldT2(maskedvox);
    ccct2 = concordance_cc(Xt2, Yt2);

    [Xs1, Ys1] = collect_signal_scatter_sp(rootDir, sp.pid, selectpatient, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
        fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'T1w');

    [Xs2, Ys2] = collect_signal_scatter_sp(rootDir, sp.pid, selectpatient, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
        fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'T2w');

    [Xs3, Ys3] = collect_signal_scatter_sp(rootDir, sp.pid, selectpatient, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
        fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'FLAIR');

    cccs1 = concordance_cc(Xs1, Ys1);
    cccs2 = concordance_cc(Xs2, Ys2);
    cccs3 = concordance_cc(Xs3, Ys3);

    %
    close all
    f21 = figure('Color','w','Name','Fig21_ScatterDensityPatient',Position=[10,10,1000,600]);
    tiledlayout(2,3,'Padding','compact','TileSpacing','compact');
    % plot_density_scatter(ax, X, Y, ttl, cccPerSubject)
    plot_density_scatter(nexttile, Xpd, Ypd, 'PD:', cccpd);
    plot_density_scatter(nexttile, Xt1, Yt1, 'T1:', ccct1);
    plot_density_scatter(nexttile, Xt2, Yt2, 'T2:', ccct2);
    plot_density_scatter_sg(nexttile, Xs1, Ys1, 'T1W Signal:', cccs1);
    plot_density_scatter_sg(nexttile, Xs2, Ys2, 'T2W Signal:', cccs2);
    plot_density_scatter_sg(nexttile, Xs3, Ys3, 'FLAIR Signal:', cccs3);

    set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
    set(findall(gcf,'-property','FontSize'), 'FontSize', 12);

    save_figure(f21, outDir, sprintf('Figure2_ScatterDensityPatient_%s',Store(selectpatient).pid),  savePNG, savePDF, saveFIG, dpi);
end
%% ================================================================
% FIGURE 2 — Voxel-wise agreement scatter for all patient(Held-out vs GT) (density)
% ================================================================
% Collect sampled voxels across all patients
[XPD, YPD] = collect_scatter_samples(Store, 'PD', maxVoxScatter);
[XT1, YT1] = collect_scatter_samples(Store, 'T1', maxVoxScatter);
[XT2, YT2] = collect_scatter_samples(Store, 'T2', maxVoxScatter);

% Aggregate across all patients for each contrast (density scatter)
[XS1, YS1] = collect_signal_scatter(rootDir, PatientID, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
    fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'T1w', maxVoxScatter);


[XS2, YS2] = collect_signal_scatter(rootDir, PatientID, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
    fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'T2w', maxVoxScatter);


[XS3, YS3] = collect_signal_scatter(rootDir, PatientID, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
    fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, 'FLAIR', maxVoxScatter);

f2 = figure('Color','w','Name','Fig2_ScatterDensity',Position=[10,10,1000,600]);
tiledlayout(2,3,'Padding','compact','TileSpacing','compact');
% plot_density_scatter(ax, X, Y, ttl, cccPerSubject)
plot_density_scatter(nexttile, XPD, YPD, 'PD: ', held_CCC(:,1));
plot_density_scatter(nexttile, XT1, YT1, 'T1: ', held_CCC(:,2));
plot_density_scatter(nexttile, XT2, YT2, 'T2: ', held_CCC(:,3));
plot_density_scatter_sg(nexttile, XS1, YS1, 'T1W Signal:', []);
plot_density_scatter_sg(nexttile, XS2, YS2, 'T2W Signal:', []);
plot_density_scatter_sg(nexttile, XS3, YS3, 'FLAIR Signal:', []);
% save_figure(fS2, outDir, 'SuppFigure_S2_SignalConsistency',savePNG, savePDF, saveFIG, dpi);% savePNG, savePDF, dpi);


set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
set(findall(gcf,'-property','FontSize'), 'FontSize', 12);

save_figure(f2, outDir, 'Figure3_ScatterDensityAllPid',  savePNG, savePDF, saveFIG, dpi);

%% ================================================================
% FIGURE 3 — Bland–Altman (ROI-wise if available, else voxel-wise)
% ================================================================
f3 = figure('Color','w','Name','Fig3_BlandAltman');
tiledlayout(1,3,'Padding','compact','TileSpacing','compact');

for m=1:nMaps
    ax = nexttile;
    [meanVals, diffVals, meanVals_in, diffVals_in] = collect_ba_data(Store, ROIs, roiMode, mapNames(m));
    if isempty(meanVals)
        text(ax,0.5,0.5,'No BA data','HorizontalAlignment','center'); axis(ax,'off');
        continue;
    end
    plot_bland_altman(ax, meanVals, diffVals, meanVals_in, diffVals_in, sprintf('%s Bland–Altman', mapNames(m)));
end
set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
set(findall(gcf,'-property','FontSize'), 'FontSize', 14);


save_figure(f3, outDir, 'Figure3_BlandAltman', savePNG, savePDF, saveFIG, dpi);% savePNG, savePDF, dpi);

%% ================================================================
% FIGURE 4 — Per-subject distribution: In-training (10 folds) + Held-out
% ================================================================
close all
f4 = figure('Color','w','Name','Fig4_PerSubject_Distributions',Position=[10,10,500,600]);
tiledlayout(3,1,'Padding','compact','TileSpacing','compact');

for m=1:nMaps
    ax = nexttile;
    plot_per_subject_intrain_vs_held(ax, squeeze(MAE(:,:,m)), held_MAE(:,m), mapNames(m));
end
set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
set(findall(gcf,'-property','FontSize'), 'FontSize', 12);


save_figure(f4, outDir, 'Figure4_PerSubject_InTrainVsHeld', savePNG, savePDF, saveFIG, dpi);%savePNG, savePDF, dpi);

%% ================================================================
% FIGURE 5 — Uncertainty proxy: std of 10 in-training predictions
%          + does std predict held-out error?
% ================================================================
% Pick one subject to display (median held-out T1 MAE)
[~,ord] = sort(held_MAE(:,2),'ascend');
pU = ord(round(N/2));
mask = Store(pU).mask;
z = choose_best_slice(mask);

f5 = figure('Color','w','Name','Fig5_EnsembleStd_And_ErrorCorrelation');
tiledlayout(2,3,'Padding','compact','TileSpacing','compact');

% Top row: std maps (PD/T1/T2)
stds = {Store(pU).stdInPD, Store(pU).stdInT1, Store(pU).stdInT2};
for m=1:nMaps
    ax = nexttile;
    S = stds{m};
    if isempty(S), axis off; continue; end
    imagesc(S(:,:,z)); axis image off; colormap(gray);
    v = S(mask); if ~isempty(v), caxis([0 prctile(v,98)]); end
    title(sprintf('%s std (In-training ensemble)\n%s', mapNames(m), Store(pU).pid), 'Interpreter','none');
end

% Bottom row: bin-averaged relationship std vs |error| on held-out
refs = {Store(pU).refPD, Store(pU).refT1, Store(pU).refT2};
held = {Store(pU).heldPD, Store(pU).heldT1, Store(pU).heldT2};

for m=1:nMaps
    ax = nexttile;
    R = refs{m}; H = held{m}; S = stds{m};
    if isempty(R) || isempty(H) || isempty(S), axis off; continue; end
    e = abs(H - R);
    x = S(mask); y = e(mask);
    % Remove NaNs
    ok = isfinite(x) & isfinite(y);
    x=x(ok); y=y(ok);

    % Bin by std
    nb = 30;
    edges = linspace(min(x), max(x), nb+1);
    xc = nan(nb,1); yc = nan(nb,1);
    for b=1:nb
        ii = x>=edges(b) & x<edges(b+1);
        if any(ii)
            xc(b) = mean(x(ii));
            yc(b) = mean(y(ii));
        end
    end
    plot(ax, x, y, '.', 'MarkerSize', 2); hold(ax,'on');
    plot(ax, xc, yc, '-', 'LineWidth', 2);
    grid(ax,'on'); xlabel(ax,'Ensemble std'); ylabel(ax,'|Held-out error|');
    title(ax, sprintf('%s: std vs |error|', mapNames(m)));
end

set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
set(findall(gcf,'-property','FontSize'), 'FontSize', 14);


save_figure(f5, outDir, 'Figure5_StdMaps_StdVsError', savePNG, savePDF, saveFIG, dpi);%savePNG, savePDF, dpi);

%% ================================================================
% SUPPLEMENTAL: S2 Signal consistency (Measured vs Synthesized)
% ================================================================
if makeSupplement_S2_signalConsistency


    % Also save a supplemental signal table (overall held-out)
    held_sig_MAE  = squeeze(diag3(MAE_sig));
    held_sig_RMSE = squeeze(diag3(RMSE_sig));
    held_sig_CCC  = squeeze(diag3(CCC_sig));
    STableSig = table(contrastNames', ...
        mean(held_sig_MAE,1,'omitnan')',  std(held_sig_MAE,0,1,'omitnan')', ...
        mean(held_sig_RMSE,1,'omitnan')', std(held_sig_RMSE,0,1,'omitnan')', ...
        mean(held_sig_CCC,1,'omitnan')',  std(held_sig_CCC,0,1,'omitnan')', ...
        'VariableNames', {'Contrast','MAE_mean','MAE_std','RMSE_mean','RMSE_std','CCC_mean','CCC_std'});

    writetable(STableSig, fullfile(outDir,'SuppTable_SignalConsistency.xlsx'));
    writetable(STableSig, fullfile(outDir,'SuppTable_SignalConsistency.csv'));
end

%% ================================================================
% SUPPLEMENTAL: Gain maps montage (optional)
% ================================================================
if makeSupplement_gainMaps
    % Pick median subject and show g1/g2/g3 for held-out fold
    pG = ord(round(N/2));
    pid = PatientID(pG);
    pDir = fullfile(rootDir, pid);
    foldDir = fullfile(pDir, sprintf('P%dL1OutPred', pG));
    if exist(foldDir,'dir')
        g1 = single(load_nii_gz(fullfile(foldDir, fname_g1pred)));
        g2 = single(load_nii_gz(fullfile(foldDir, fname_g2pred)));
        g3 = single(load_nii_gz(fullfile(foldDir, fname_g3pred)));
        mask = Store(pG).mask;
        z = choose_best_slice(mask);

        fG = figure('Color','w','Name','Supp_GainMaps');
        tiledlayout(1,3,'Padding','compact','TileSpacing','compact');
        nexttile; imagesc(g1(:,:,z)); axis image off; colormap(gray);
        v=g1(mask); if ~isempty(v), caxis(prctile(v,[2 98])); end; title(sprintf('g1 (held-out) %s', pid),'Interpreter','none');
        nexttile; imagesc(g2(:,:,z)); axis image off; colormap(gray);
        v=g2(mask); if ~isempty(v), caxis(prctile(v,[2 98])); end; title('g2 (held-out)');
        nexttile; imagesc(g3(:,:,z)); axis image off; colormap(gray);
        v=g3(mask); if ~isempty(v), caxis(prctile(v,[2 98])); end; title('g3 (held-out)');

        set(findall(gcf,'-property','FontName'), 'FontName', 'Times New Roman');
        set(findall(gcf,'-property','FontSize'), 'FontSize', 14);

        save_figure(fG, outDir, 'SuppFigure_GainMaps',savePNG, savePDF, saveFIG, dpi);% savePNG, savePDF, dpi);
    end
end

%% ================================================================
% SUPPLEMENTAL: Fold-by-fold table (optional)
% ================================================================
if makeSupplement_foldTable
    % For each fold x, report mean held-out metrics of the one held-out subject (i.e., diagonal already)
    ST_fold = table((1:N)', PatientID(:), held_MAE(:,1), held_MAE(:,2), held_MAE(:,3), held_CCC(:,1), held_CCC(:,2), held_CCC(:,3), ...
        'VariableNames', {'Fold','HeldOutPatientID','HeldMAE_PD','HeldMAE_T1','HeldMAE_T2','HeldCCC_PD','HeldCCC_T1','HeldCCC_T2'});
    writetable(ST_fold, fullfile(outDir,'SuppTable_FoldByFold.xlsx'));
    writetable(ST_fold, fullfile(outDir,'SuppTable_FoldByFold.csv'));
end

%% ================================================================
% SUPPLEMENTAL: Tissue-wise table (only if kmeans ROIs enabled)
% ================================================================
if makeSupplement_tissueWiseTable && strcmpi(roiMode,'kmeans')
    % Compute ROI-wise held-out MAE for each patient and map
    roiNames = ["ROI_lowT1","ROI_midT1","ROI_highT1"]; % will be re-labeled per patient after sorting
    ST_roi = table();
    rows = [];
    for p=1:N
        if isempty(ROIs{p}) || isempty(Store(p).heldT1), continue; end
        mask = Store(p).mask;
        ref = {Store(p).refPD, Store(p).refT1, Store(p).refT2};
        held = {Store(p).heldPD, Store(p).heldT1, Store(p).heldT2};
        roi = ROIs{p}; % struct with cell array roi.masks{k}
        for k=1:numel(roi.masks)
            mk = roi.masks{k} & mask;
            if nnz(mk)<100, continue; end
            vals = nan(1,nMaps);
            for m=1:nMaps
                vals(m) = mean(abs(held{m}(mk)-ref{m}(mk)),'omitnan');
            end
            rows = [rows; {Store(p).pid, k, nnz(mk), vals(1), vals(2), vals(3)}];
        end
    end
    if ~isempty(rows)
        ST_roi = cell2table(rows, 'VariableNames', {'PatientID','ROIindex','nVox','MAE_PD','MAE_T1','MAE_T2'});
        writetable(ST_roi, fullfile(outDir,'SuppTable_TissueWise_KmeansROIs.xlsx'));
        writetable(ST_roi, fullfile(outDir,'SuppTable_TissueWise_KmeansROIs.csv'));
    end
end

fprintf('\nAll small figures and All outputs saved to:\n  %s\n', outDir);
%% All patients 3M voxel historgram
%%% ================================================================
% Overlapping histograms for all patients
% PD, T1, T2, T1W, T2W, FLAIR
% ================================================================
close all
f24 = figure('Color','w','Position',[100 100 1200 600]);
tiledlayout(2,3,'Padding','compact','TileSpacing','compact');

% Put all variables in cell arrays
Xall = {XPD, XT1, XT2, XS1, XS2, XS3};
Yall = {YPD, YT1, YT2, YS1, YS2, YS3};
names = {'PD','T1','T2','T1W','T2W','FLAIR'};

for i = 1:6

    ax = nexttile;
    hold(ax,'on');

    X = double(Xall{i}(:));
    Y = double(Yall{i}(:));

    % Remove NaNs
    ok = isfinite(X) & isfinite(Y);
    X = X(ok);
    Y = Y(ok);

    if isempty(X) || isempty(Y)
        text(0.5,0.5,'No data','HorizontalAlignment','center');
        axis off
        continue;
    end

    % ------------------------------------------------------------
    % Common range (from combined data)
    % ------------------------------------------------------------
    allVals = [X; Y];
    xmin = min(allVals);
    xmax = max(allVals);

    if xmin == xmax
        xmin = xmin - 1;
        xmax = xmax + 1;
    end

    % ------------------------------------------------------------
    % Adaptive binning (Freedman–Diaconis)
    % ------------------------------------------------------------
    n = numel(allVals);
    q75 = prctile(allVals,75);
    q25 = prctile(allVals,25);
    iqrVal = q75 - q25;

    if iqrVal > 0
        binWidth = 2 * iqrVal * n^(-1/3);
    else
        binWidth = (xmax - xmin)/100;
    end

    if ~isfinite(binWidth) || binWidth <= 0
        binWidth = (xmax - xmin)/100;
    end

    nBins = ceil((xmax - xmin)/binWidth);
    nBins = max(nBins,30);
    nBins = min(nBins,100);

    edges = linspace(xmin, xmax, nBins+1);

    % ------------------------------------------------------------
    % Plot overlapping histograms (FILLED)
    % ------------------------------------------------------------
    h1 = histogram(ax, X, edges, ...
        'Normalization','count', ...
        'FaceAlpha',0.45, ...
        'EdgeAlpha',0.2, ...
        'DisplayStyle','bar');

    h2 = histogram(ax, Y, edges, ...
        'Normalization','count', ...
        'FaceAlpha',0.45, ...
        'EdgeAlpha',0.2, ...
        'DisplayStyle','bar');

    % Colors
    h1.FaceColor = [0 0.4470 0.7410];      % blue
    h2.FaceColor = [0.8500 0.3250 0.0980]; % orange

    % ------------------------------------------------------------
    % Formatting
    % ------------------------------------------------------------
    xlim([xmin xmax]);
    box(ax,'on');
    ax.LineWidth = 1;

    % Hide y-axis ticks but keep box
    ax.YTick = [];
    ax.YColor = 'k';

    xlabel(names{i});
    title(names{i},'FontWeight','normal');

    % ------------------------------------------------------------
    % Legend (only once)
    % ------------------------------------------------------------
    if i == 2
        lgd = legend(ax, {'Ground Truth ','Prediction'}, ...
            'Location','northoutside');
        lgd.Box = 'off';
        lgd.NumColumns = 2;
        lgd.Orientation = 'horizontal';

    elseif i == 5
        lgd = legend(ax, {'Measured','Calculated'}, ...
            'Location','northoutside');
        lgd.Box = 'off';
        lgd.NumColumns = 2;
        lgd.Orientation = 'horizontal';
    end

end

% Global formatting
set(findall(gcf,'-property','FontName'),'FontName','Times New Roman');
set(findall(gcf,'-property','FontSize'),'FontSize',14);
save_figure(gcf, outDir, 'Figure4_OverlappedHistogramsAllPid',  savePNG, savePDF, saveFIG, dpi);%

%% ================================================================
% BOXPLOT SUMMARY FIGURES
% One independent figure per quantity:
%   PD, T1, T2, T1W, T2W, FLAIR
%
% For each figure:
%   x-axis = patient number (1...N)
%   at each patient -> two boxplots:
%       Reference/Measured/Acquired
%       Prediction/Calculated
%
% Uses full 3D masked voxels for each patient
% ================================================================

% Example patient set
pick = 1:11;

showLegend = true;

% ------------------------------------------------
% Quantities to plot
% ------------------------------------------------
plotDefs = {
    'PD',    'refPD',      'heldPD',      'Ground Truth', 'Prediction'
    'T1',    'refT1',      'heldT1',      'Ground Truth', 'Prediction'
    'T2',    'refT2',      'heldT2',      'Ground Truth', 'Prediction'
    'T1W',   'measT1w',    'calcT1w',     'Acquired',     'Calculated'
    'T2W',   'measT2w',    'calcT2w',     'Acquired',     'Calculated'
    'FLAIR', 'measFLAIR',  'calcFLAIR',   'Acquired',     'Calculated'
    };

% ------------------------------------------------
% Loop over quantities
% ------------------------------------------------
for q = 3%:size(plotDefs,1)

    qName     = plotDefs{q,1};
    refField  = plotDefs{q,2};
    predField = plotDefs{q,3};
    lab1      = plotDefs{q,4};
    lab2      = plotDefs{q,5};

    % close all
    fB = figure('Color','w', ...
        'Name', sprintf('BoxPlot_%s', qName), ...
        'Units','pixels', ...
        'Position', [100 100 1200 500]);

    ax = axes(fB);
    hold(ax,'on');

    % ------------------------------------------------
    % Collect data for all patients
    % ------------------------------------------------
    allVals = [];
    groupPatient = [];
    groupType = [];

    % groupType:
    %   1 = reference/measured/acquired
    %   2 = prediction/calculated
    for ii = 1:numel(pick)

        p = pick(ii);

        if p > numel(Store) || isempty(Store(p).mask)
            fprintf('[Skip] Missing mask for patient %d\n', p);
            continue;
        end

        mask = Store(p).mask;

        if ~isfield(Store, refField) || ~isfield(Store, predField)
            error('Field %s or %s not found in Store.', refField, predField);
        end

        R = Store(p).(refField);
        H = Store(p).(predField);

        if isempty(R) || isempty(H)
            fprintf('[Skip] Missing %s data for patient %d\n', qName, p);
            continue;
        end

        idx = mask & isfinite(R) & isfinite(H);

        rVals = double(R(idx));
        hVals = double(H(idx));

        if isempty(rVals) || isempty(hVals)
            fprintf('[Skip] No valid voxels for %s patient %d\n', qName, p);
            continue;
        end

        % Append reference/measured
        allVals      = [allVals; rVals(:)];
        groupPatient = [groupPatient; repmat(ii, numel(rVals), 1)];
        groupType    = [groupType; ones(numel(rVals),1)];

        % Append prediction/calculated
        allVals      = [allVals; hVals(:)];
        groupPatient = [groupPatient; repmat(ii, numel(hVals), 1)];
        groupType    = [groupType; 2*ones(numel(hVals),1)];
    end

    if isempty(allVals)
        text(0.5,0.5,sprintf('No data available for %s', qName), ...
            'HorizontalAlignment','center');
        axis off
        continue;
    end

    % ------------------------------------------------
    % Create grouped boxplot
    % ------------------------------------------------
    % positions: for each patient i, place two boxes at i-0.18 and i+0.18
    pos = nan(size(allVals));
    for ii = 1:numel(pick)
        pos(groupPatient==ii & groupType==1) = ii - 0.18;
        pos(groupPatient==ii & groupType==2) = ii + 0.18;
    end

    boxplot(ax, allVals, {groupPatient, groupType}, ...
        'Positions', unique(pos), ...
        'Widths', 0.28, ...
        'FactorSeparator', 1, ...
        'Symbol', '', ...
        'Colors', [0 0.4470 0.7410; 0.8500 0.3250 0.0980]);

    % ------------------------------------------------
    % Beautify box colors (patch fill)
    % MATLAB boxplot makes line boxes by default, so patch them
    % ------------------------------------------------
    h = findobj(ax,'Tag','Box');
    nBoxes = numel(h);

    % Reverse order handling because boxplot objects come reversed
    for j = 1:nBoxes
        patch(get(h(j),'XData'), get(h(j),'YData'), ...
            get_box_color(j), ...
            'FaceAlpha', 0.35, ...
            'EdgeColor', get_box_color(j), ...
            'LineWidth', 1.0);
    end

    % Keep median/whiskers visible
    set(findobj(ax,'Tag','Median'), 'LineWidth', 1.2, 'Color', 'k');
    set(findobj(ax,'Tag','Whisker'), 'LineWidth', 0.8);
    set(findobj(ax,'Tag','Upper Whisker'), 'LineWidth', 0.8);
    set(findobj(ax,'Tag','Lower Whisker'), 'LineWidth', 0.8);
    set(findobj(ax,'Tag','Upper Adjacent Value'), 'LineWidth', 0.8);
    set(findobj(ax,'Tag','Lower Adjacent Value'), 'LineWidth', 0.8);

    % ------------------------------------------------
    % Axis formatting
    % ------------------------------------------------
    xlim(ax, [0.5 numel(pick)+0.5]);
    xticks(ax, 1:numel(pick));
    xticklabels(ax, string(pick));
    xlabel(ax, 'Patient number');
    ylabel(ax, qName);

    box(ax,'on');
    ax.LineWidth = 0.75;
    ax.FontName = 'Times New Roman';
    ax.FontSize = 14;

    title(ax, sprintf('%s distribution across patients', qName), ...
        'FontWeight','normal');

    % ------------------------------------------------
    % Legend
    % ------------------------------------------------
    if showLegend
        p1 = patch(nan, nan, [0 0.4470 0.7410], ...
            'FaceAlpha', 0.35, 'EdgeColor', [0 0.4470 0.7410]);
        p2 = patch(nan, nan, [0.8500 0.3250 0.0980], ...
            'FaceAlpha', 0.35, 'EdgeColor', [0.8500 0.3250 0.0980]);

        lgd = legend(ax, [p1 p2], {lab1, lab2}, ...
            'Location', 'northoutside');
        lgd.Box = 'off';
        lgd.NumColumns = 2;
        lgd.Orientation = 'horizontal';
    end

    % ------------------------------------------------
    % Save
    % ------------------------------------------------
    save_figure(fB, outDir, sprintf('Figure_BoxPlot_%s_PerPatient', qName), ...
        savePNG, savePDF, saveFIG, dpi);
end
%% ===================== LOCAL FUNCTIONS =========================
function V = load_nii_gz(fpath)
% Load .nii or .nii.gz using a temp gunzip when needed
if ~exist(fpath,'file')
    error('File not found: %s', fpath);
end
[~,~,ext] = fileparts(fpath);
if strcmpi(ext,'.gz')
    tmpDir = tempname;
    mkdir(tmpDir);
    gunzip(fpath, tmpDir);
    % Remove .gz extension
    [~,nameNoGz,~] = fileparts(fpath); % returns .nii as ext here
    niiPath = fullfile(tmpDir, nameNoGz);
    V = niftiread(niiPath);
    % cleanup
    try rmdir(tmpDir,'s'); catch, end
else
    V = niftiread(fpath);
end
V = single(V);
end

function [mae, rmse, nrmse, bias, ccc] = compute_metrics(gt, pr, mask)
% Masked metrics (ignores NaNs)
gt = single(gt); pr = single(pr);
if isempty(mask), mask = true(size(gt)); end
idx = mask & isfinite(gt) & isfinite(pr);
if nnz(idx)==0
    mae=NaN; rmse=NaN; nrmse=NaN; bias=NaN; ccc=NaN; return;
end
e = pr(idx) - gt(idx);
mae  = mean(abs(e),'omitnan');
rmse = sqrt(mean(e.^2,'omitnan'));
bias = mean(e,'omitnan');
rngv = max(gt(idx)) - min(gt(idx));
if rngv>0
    nrmse = rmse / rngv;
else
    nrmse = NaN;
end
ccc = concordance_cc(gt(idx), pr(idx));
end

function c = concordance_cc(x,y)
% Lin's concordance correlation coefficient
x = double(x(:)); y = double(y(:));
ok = isfinite(x) & isfinite(y);
x = x(ok); y = y(ok);
if numel(x)<3, c = NaN; return; end
mx = mean(x); my = mean(y);
vx = var(x,1); vy = var(y,1);
sxy = mean((x-mx).*(y-my));
c = (2*sxy) / (vx + vy + (mx-my)^2 + eps);
end

function z = choose_best_slice(mask)
% Choose axial slice with largest mask area
if isempty(mask), z = round(size(mask,3)/2); return; end
a = squeeze(sum(sum(mask,1),2));
[~,z] = max(a);
if isempty(z) || z<1, z = round(size(mask,3)/2); end
end

function A = diag3(X)
% Extract diagonal across first two dims for each third dim:
% X is N x N x K -> returns N x K
N = size(X,1);
K = size(X,3);
A = nan(N,K);
for k=1:K
    A(:,k) = diag(X(:,:,k));
end
end


function save_figure(fig, outDir, baseName, savePNG, savePDF, saveFIG, dpi)

if ~exist(outDir,'dir')
    mkdir(outDir);
end

% Save PNG
if savePNG
    print(fig, fullfile(outDir, baseName + ".png"), ...
        '-dpng', sprintf('-r%d', dpi));
end

% Save PDF (vector format)
if savePDF
    print(fig, fullfile(outDir, baseName + ".pdf"), ...
        '-dpdf', '-painters');
end

% Save MATLAB FIG (editable)
if saveFIG
    savefig(fig, fullfile(outDir, baseName + ".fig"));
end
if saveFIG
    figFile = fullfile(outDir, baseName + ".fig");
    tempFig = fullfile(tempdir, baseName + ".fig");

    if exist(tempFig, 'file')
        delete(tempFig);
    end

    try
        savefig(fig, tempFig);

        if exist(figFile, 'file')
            delete(figFile);
        end

        copyfile(tempFig, figFile);
    catch ME
        warning('Could not save FIG file: %s', ME.message);
    end
end
end


function [Xall, Yall] = collect_scatter_samples(Store, whichMap, maxVox)
% Collect held-out vs GT voxels across all patients (random sample)
Xall = []; Yall = [];
for p=1:numel(Store)
    mask = Store(p).mask;
    if isempty(mask), continue; end
    switch upper(whichMap)
        case 'PD'
            gt = Store(p).refPD; pr = Store(p).heldPD;
        case 'T1'
            gt = Store(p).refT1; pr = Store(p).heldT1;
        case 'T2'
            gt = Store(p).refT2; pr = Store(p).heldT2;
    end
    if isempty(gt) || isempty(pr), continue; end
    idx = mask & isfinite(gt) & isfinite(pr);
    vgt = gt(idx); vpr = pr(idx);
    n = numel(vgt);
    if n==0, continue; end
    % sample proportionally but cap
    take = min(n, ceil(maxVox / max(1,numel(Store))));
    rp = randperm(n, take);
    Xall = [Xall; vgt(rp)];
    Yall = [Yall; vpr(rp)];
    if numel(Xall) >= maxVox
        Xall = Xall(1:maxVox); Yall = Yall(1:maxVox);
        return;
    end
end
end

function plot_density_scatter2(ax, X, Y, ttl, cccPerSubject)
% Density scatter using 2D histogram
axes(ax);
if isempty(X) || isempty(Y)
    text(0.5,0.5,'No data','HorizontalAlignment','center'); axis off; return;
end
X = double(X(:)); Y = double(Y(:));
ok = isfinite(X) & isfinite(Y);
X = X(ok); Y = Y(ok);
if numel(X) > 200000
    rp = randperm(numel(X), 200000);
    X = X(rp); Y = Y(rp);
end
nb = 200;
xmin=min(X); xmax=max(X); ymin=min(Y); ymax=max(Y);
if xmin==xmax, xmax=xmin+1; end
if ymin==ymax, ymax=ymin+1; end
% edgesX = linspace(xmin, xmax, nb);
% edgesY = linspace(ymin, ymax, nb);
% H = histcounts2(X, Y, edgesX, edgesY);
% imagesc(edgesX, edgesY, log1p(H)'); axis xy; axis tight;
scatter(X, Y)
xlim([0 xmax])
xticks(ceil(linspace(0,xmax,3)))
ylim([0 xmax])
yticks(ceil(linspace(0,xmax,3)))
% colormap(gray);
hold on;
plot([xmin xmax],[xmin xmax],'-','LineWidth',1.5);
grid on;
xlabel('Ground Truth'); ylabel('Prediction');
axis square
cccAll = concordance_cc(X,Y);
txt = sprintf(' CCC(all)=%.3f', cccAll);
title([ttl, txt]);
% Show overall CCC

box on
% if ~isempty(cccPerSubject)
%     txt = sprintf('%s | mean CCC=%.3f', txt, mean(cccPerSubject,'omitnan'));
% end
text(0.02,0.98,txt,'Units','normalized','VerticalAlignment','top','Color','k','FontWeight','bold');
end
function plot_density_scatter(ax, X, Y, ttl, cccPerSubject)
% Density scatter using 2D histogram (white background, no dark empty area)

axes(ax);

if isempty(X) || isempty(Y)
    text(0.5,0.5,'No data','HorizontalAlignment','center');
    axis off;
    return;
end

% Clean inputs
X = double(X(:));
Y = double(Y(:));
ok = isfinite(X) & isfinite(Y);
X = X(ok);
Y = Y(ok);

% % Downsample for speed (visualization only)
% if numel(X) > 20000000
%     rp = randperm(numel(X), 200000);
%     X = X(rp);
%     Y = Y(rp);
% end

% 2D histogram bins
nb = 201;
xmin = 0;%min(X);
xmax = ceil((max(max(X),max(Y)))/10)*10;
ymin = 0;%min(Y);
ymax = ceil((max(max(X),max(Y)))/10)*10;%max(Y);
if xmin==xmax, xmax = xmin+1; end
if ymin==ymax, ymax = ymin+1; end

edgesX = linspace(xmin, xmax, nb);
edgesY = linspace(ymin, ymax, nb);

H = histcounts2(X, Y, edgesX, edgesY);

% Key fix: make zero-count bins NaN so they render as axes background (white)
% H(H==0) = NaN;

% Plot log-density
imagesc(edgesX, edgesY, log1p(H)');
axis xy; axis tight;

colormap(gray);
set(gca, 'Color', 'w');   % NaNs show as white background

hold on;
plot([xmin xmax], [xmin xmax], 'r-', 'LineWidth', 0.5);
% grid on;
xlim([xmin,xmax])
xlim([ymin,ymax])
xticks(linspace(xmin,xmax,3))
yticks(linspace(ymin,ymax,3))
xlabel('Ground Truth');
ylabel('Prediction');
xlabel('Ground Truth'); ylabel('Prediction');
axis square
cccAll = concordance_cc(X,Y);
txt = sprintf(' CCC = %.2f', cccAll);
title([ttl, txt]);
% title(ttl);

% % CCC annotation
% cccAll = concordance_cc(X, Y);
% txt = sprintf('CCC(all)=%.3f', cccAll);
% if ~isempty(cccPerSubject)
%     txt = sprintf('%s | mean CCC=%.3f', txt, mean(cccPerSubject,'omitnan'));
% end

% Text color should be dark on white background
% text(0.02, 0.98, txt, ...
%     'Units','normalized', ...
%     'VerticalAlignment','top', ...
%     'Color','k', ...
%     'FontWeight','bold');
end
function plot_density_scatter_sg(ax, X, Y, ttl, cccPerSubject)
% Density scatter using 2D histogram (white background, no dark empty area)

axes(ax);

if isempty(X) || isempty(Y)
    text(0.5,0.5,'No data','HorizontalAlignment','center');
    axis off;
    return;
end

% Clean inputs
X = double(X(:));
Y = double(Y(:));
ok = isfinite(X) & isfinite(Y);
X = X(ok);
Y = Y(ok);

% Downsample for speed (visualization only)
if numel(X) > 200000
    rp = randperm(numel(X), 200000);
    X = X(rp);
    Y = Y(rp);
end

% 2D histogram bins
nb = 200;
xmin = 0;%min(X);
xmax = ceil((max(max(X),max(Y)))/10)*10;
ymin = 0;%min(Y);
ymax = ceil((max(max(X),max(Y)))/10)*10;%max(Y);
if xmin==xmax, xmax = xmin+1; end
if ymin==ymax, ymax = ymin+1; end

edgesX = linspace(xmin, xmax, nb);
edgesY = linspace(ymin, ymax, nb);

H = histcounts2(X, Y, edgesX, edgesY);

% Key fix: make zero-count bins NaN so they render as axes background (white)
% H(H==0) = NaN;

% Plot log-density
imagesc(edgesX, edgesY, log1p(H)');
axis xy; axis tight;

colormap(gray);
set(gca, 'Color', 'w');   % NaNs show as white background

hold on;
plot([xmin xmax], [xmin xmax], 'r-', 'LineWidth', 0.5);
% grid on;
xlim([xmin,xmax])
xlim([ymin,ymax])
xticks(linspace(xmin,xmax,3))
yticks(linspace(ymin,ymax,3))
xlabel('Acquired');
ylabel('Calculated');
axis square
cccAll = concordance_cc(X,Y);
txt = sprintf(' CCC = %.2f', cccAll);
title([ttl, txt]);
% title(ttl);

% % CCC annotation
% cccAll = concordance_cc(X, Y);
% txt = sprintf('CCC(all)=%.3f', cccAll);
% if ~isempty(cccPerSubject)
%     txt = sprintf('%s | mean CCC=%.3f', txt, mean(cccPerSubject,'omitnan'));
% end

% Text color should be dark on white background
% text(0.02, 0.98, txt, ...
%     'Units','normalized', ...
%     'VerticalAlignment','top', ...
%     'Color','k', ...
%     'FontWeight','bold');
end


function roi = make_kmeans_rois(T1, T2, mask, K, maxVox)
% Build pseudo tissue ROIs via kmeans in (T1,T2) space (GT)
% Returns roi.masks{1..K} sorted by increasing mean T1
idx = mask & isfinite(T1) & isfinite(T2);
t1 = double(T1(idx)); t2 = double(T2(idx));
n = numel(t1);
if n==0
    roi = []; return;
end
if n>maxVox
    rp = randperm(n, maxVox);
    t1s = t1(rp); t2s = t2(rp);
else
    t1s = t1; t2s = t2;
end
X = [t1s(:), t2s(:)];
% kmeans
try
    lab = kmeans(X, K, 'Replicates', 3, 'MaxIter', 200);
catch
    roi = []; return;
end
% Assign full volume using nearest centroid (fast approximation):
% For simplicity, run kmeans on sampled, then compute centroids, then assign all vox.
C = zeros(K,2);
for k=1:K
    C(k,:) = mean(X(lab==k,:),1);
end
t1all = double(T1(idx)); t2all = double(T2(idx));
Xall = [t1all(:), t2all(:)];
D = pdist2(Xall, C);
labAll = zeros(size(t1all));
[~,labAll] = min(D,[],2);

% Create masks
masks = cell(K,1);
lin = find(idx);
for k=1:K
    mk = false(size(mask));
    mk(lin(labAll==k)) = true;
    masks{k} = mk;
end

% Sort by mean T1 (low->high)
mT1 = zeros(K,1);
for k=1:K
    mT1(k) = mean(T1(masks{k}),'omitnan');
end
[~,ord] = sort(mT1,'ascend');
roi.masks = masks(ord);
roi.meanT1 = mT1(ord);
end

function [meanVals, diffVals, meanVals_in, diffVals_in] = collect_ba_data(Store, ROIs, roiMode, mapName)
% Collect Bland–Altman (Held-out and In-training mean) either ROI-wise or voxel-wise
% Returns vectors for plotting:
%   meanVals, diffVals: held-out
%   meanVals_in, diffVals_in: mean-in-training
meanVals = []; diffVals = [];
meanVals_in = []; diffVals_in = [];
for p=1:numel(Store)
    mask = Store(p).mask;
    if isempty(mask), continue; end
    switch upper(mapName)
        case 'PD'
            gt = Store(p).refPD; ho = Store(p).heldPD; mi = Store(p).meanInPD;
        case 'T1'
            gt = Store(p).refT1; ho = Store(p).heldT1; mi = Store(p).meanInT1;
        case 'T2'
            gt = Store(p).refT2; ho = Store(p).heldT2; mi = Store(p).meanInT2;
    end
    if isempty(gt) || isempty(ho) || isempty(mi), continue; end

    if strcmpi(roiMode,'kmeans') && ~isempty(ROIs{p})
        roi = ROIs{p};
        for k=1:numel(roi.masks)
            mk = roi.masks{k} & mask;
            if nnz(mk)<200, continue; end
            gtR = mean(gt(mk),'omitnan');
            hoR = mean(ho(mk),'omitnan');
            miR = mean(mi(mk),'omitnan');
            meanVals    = [meanVals; mean([gtR, hoR])];
            diffVals    = [diffVals; (hoR - gtR)];
            meanVals_in = [meanVals_in; mean([gtR, miR])];
            diffVals_in = [diffVals_in; (miR - gtR)];
        end
    else
        idx = mask & isfinite(gt) & isfinite(ho) & isfinite(mi);
        g = gt(idx); h = ho(idx); m = mi(idx);
        % downsample heavily for BA
        n = numel(g);
        if n>50000
            rp = randperm(n, 50000);
            g=g(rp); h=h(rp); m=m(rp);
        end
        meanVals    = [meanVals; mean([g,h],2)];
        diffVals    = [diffVals; (h-g)];
        meanVals_in = [meanVals_in; mean([g,m],2)];
        diffVals_in = [diffVals_in; (m-g)];
    end
end
end

function plot_bland_altman(ax, meanVals, diffVals, meanVals_in, diffVals_in, ttl)
% Overlay Held-out vs Mean-in-training BA
axes(ax);
hold on;
plot(meanVals, diffVals, '.', 'MarkerSize', 6);
plot(meanVals_in, diffVals_in, '.', 'MarkerSize', 6);

% Lines for held-out stats
mu = mean(diffVals,'omitnan');
sd = std(diffVals,0,'omitnan');
loa1 = mu - 1.96*sd; loa2 = mu + 1.96*sd;
xlim_auto = [min([meanVals;meanVals_in]), max([meanVals;meanVals_in])];
if ~all(isfinite(xlim_auto)), xlim_auto=[0 1]; end

plot(xlim_auto, [mu mu], '-', 'LineWidth', 2);
plot(xlim_auto, [loa1 loa1], '--', 'LineWidth', 1.5);
plot(xlim_auto, [loa2 loa2], '--', 'LineWidth', 1.5);

grid on;
xlabel('Mean(GT,Pred)'); ylabel('Pred - GT');
title(ttl);
legend({'Held-out','Mean(In-training)','Bias (held-out)','LoA (held-out)'}, 'Location','best');
end

function plot_per_subject_intrain_vs_held(ax, MAE_px, held_p, mapName)
% MAE_px: N x N (patient x fold) for one map
% held_p:  N x 1 (diagonal)
axes(ax);
N = size(MAE_px,1);
hold on;
maxMAE = [];
for p=1:N
    idx = setdiff(1:N, p);
    y = MAE_px(p,idx);
    y = y(isfinite(y));
    maxMAEp = max(y);
    if isempty(y), continue; end
    % boxchart at x=p
    xvals = p*ones(size(y));
    boxchart(xvals, y(:), 'BoxWidth', 0.5);
    % held-out marker
    plot(p, held_p(p), 'kd', 'MarkerFaceColor','k', 'MarkerSize',6);
    maxMAE = [maxMAE,maxMAEp];


end
box on
grid on; xlim([0 N+1]);
if mapName == 'T2'
    xlabel('Patient index'); ylabel('MAE');
    xlim([0,N+1])
    xticks(1:N)
else
    xlabel(''); ylabel('MAE');
    xlim([0,N+1])
    xticks(1:N)
    xticklabels([])
end
n = floor(log10(max(maxMAE)));
ylim2 = (ceil((max(maxMAE))/(10^n)))*(10^n);
ylim([0,ylim2+0.1*ylim2])
yticks(ceil(linspace(0,ylim2,3)))
title(sprintf('%s: In-training (box) + Held-out (diamond)', mapName), 'FontWeight','normal');
end

function [Xmeas, Ycalc] = collect_signal_scatter(rootDir, PatientID, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
    fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, which, maxVox)
% Collect measured vs synthesized voxels for held-out fold only (x=p)
Xmeas = []; Ycalc = [];
N = numel(PatientID);
for p=1:N
    pid = PatientID(p);
    pDir = fullfile(rootDir, pid);
    mask = logical(load_nii_gz(fullfile(pDir, fname_mask)));
    foldDir = fullfile(pDir, sprintf('P%dL1OutPred', p));
    if ~exist(foldDir,'dir'), continue; end
    switch upper(which)
        case 'T1W'
            meas = single(load_nii_gz(fullfile(pDir, fname_T1w)));
            calc = single(load_nii_gz(fullfile(foldDir, fname_T1w_calc)));
        case 'T2W'
            meas = single(load_nii_gz(fullfile(pDir, fname_T2w)));
            calc = single(load_nii_gz(fullfile(foldDir, fname_T2w_calc)));
        otherwise
            meas = single(load_nii_gz(fullfile(pDir, fname_FLAIR)));
            calc = single(load_nii_gz(fullfile(foldDir, fname_FLAIR_calc)));
    end
    idx = mask & isfinite(meas) & isfinite(calc);
    xm = meas(idx); yc = calc(idx);
    n = numel(xm);
    if n==0, continue; end
    take = min(n, ceil(maxVox / max(1,N)));
    rp = randperm(n, take);
    Xmeas = [Xmeas; xm(rp)];
    Ycalc = [Ycalc; yc(rp)];
    if numel(Xmeas) >= maxVox
        Xmeas = Xmeas(1:maxVox); Ycalc = Ycalc(1:maxVox);
        return;
    end
end
end

function [Xmeas, Ycalc] = collect_signal_scatter_sp(rootDir, PatientID, selectpatient, fname_mask, fname_T1w, fname_T2w, fname_FLAIR, ...
    fname_T1w_calc, fname_T2w_calc, fname_FLAIR_calc, which)
% Collect measured vs synthesized voxels for held-out fold only (x=p)
Xmeas = []; Ycalc = [];
N = numel(PatientID);

pid = PatientID;
pDir = fullfile(rootDir, pid);
mask = logical(load_nii_gz(fullfile(pDir, fname_mask)));
maskedvox = find(mask);
foldDir = fullfile(pDir, sprintf('P%dL1OutPred', selectpatient));
switch upper(which)
    case 'T1W'
        meas = single(load_nii_gz(fullfile(pDir, fname_T1w)));
        calc = single(load_nii_gz(fullfile(foldDir, fname_T1w_calc)));
    case 'T2W'
        meas = single(load_nii_gz(fullfile(pDir, fname_T2w)));
        calc = single(load_nii_gz(fullfile(foldDir, fname_T2w_calc)));
    otherwise
        meas = single(load_nii_gz(fullfile(pDir, fname_FLAIR)));
        calc = single(load_nii_gz(fullfile(foldDir, fname_FLAIR_calc)));
end
Xmeas = meas(maskedvox);
Ycalc = calc(maskedvox);
end

function info = niftiinfo_gz(fpath)
% niftiinfo for .nii or .nii.gz (temporary gunzip for header)
if ~exist(fpath,'file'), error('File not found: %s', fpath); end
[~,~,ext] = fileparts(fpath);
if strcmpi(ext,'.gz')
    tmpDir = tempname; mkdir(tmpDir);
    gunzip(fpath, tmpDir);
    [~,nameNoGz,~] = fileparts(fpath); % yields *.nii name
    niiPath = fullfile(tmpDir, nameNoGz);
    info = niftiinfo(niiPath);
    try rmdir(tmpDir,'s'); catch, end
else
    info = niftiinfo(fpath);
end
end
function write_nii_gz(V, refInfo, outGzPath)
% Write volume V using refInfo geometry to outGzPath (*.nii.gz)
% Uses niftiwrite -> gzip -> deletes .nii

V = single(V);

outGzPath = string(outGzPath);
outDir = fileparts(outGzPath);
if ~exist(outDir,'dir'), mkdir(outDir); end

% niftiwrite expects filename WITHOUT extension if you pass 'Compressed',true
% But in some MATLAB versions, Compressed for .nii.gz can be inconsistent.
% So we write .nii then gzip ourselves reliably.
base = erase(outGzPath, ".nii.gz");
tmpNii = base + ".nii";

% Ensure datatype consistent with ref
% (optional) refInfo.Datatype can be kept; but single is usually fine.
refInfo.Datatype = 'single';

niftiwrite(V, tmpNii, refInfo, 'Compressed', false);

% gzip it
gzip(tmpNii, outDir);

% gzip writes <name>.nii.gz in outDir; ensure it matches desired name
gzMade = tmpNii + ".gz";
if gzMade ~= outGzPath
    movefile(gzMade, outGzPath, 'f');
end

% cleanup .nii
if exist(tmpNii,'file'), delete(tmpNii); end
end

%% ================================================================
% Local helper for alternating box colors
% ================================================================
function c = get_box_color(j)
c1 = [0 0.4470 0.7410];
c2 = [0.8500 0.3250 0.0980];

% Because MATLAB returns box handles in reverse order
if mod(j,2)==1
    c = c2;
else
    c = c1;
end
end