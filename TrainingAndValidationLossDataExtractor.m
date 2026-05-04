clc; clear; close all;

%% ------------------ CONFIG ------------------
rootDir   = 'Z:\Desktop\hwang_cases\ProcessedData';
nSubjects = 11;                       % P1..P11
figName   = 'LossesFigure.fig';
outMat    = fullfile(rootDir, 'Tile3_LossesData_LOO.mat');

% Preallocate structs
tile3Data  = struct('folder', [], 'lines', []);
looSummary = struct('folder', [], ...
                    'subjectIndex', [], ...
                    'epochMinVal', [], ...
                    'trainLossAtMinVal', [], ...
                    'valLossMin', []);
looLossFull = struct('folder', [], ...
                     'subjectIndex', [], ...
                     'epoch', [], ...
                     'trainLoss', [], ...
                     'valLoss', []);

%% ------------------ EXTRACT TILE 3 DATA FROM EACH FIG ------------------
for p = 1:nSubjects
    folderName = fullfile(rootDir, sprintf('trained_models_P%d', p));
    figFile    = fullfile(folderName, figName);

    if ~isfile(figFile)
        warning('Figure not found for P%d: %s', p, figFile);
        continue;
    end

    % Open the figure invisibly
    fig = openfig(figFile, 'invisible');

    % Get all axes (exclude legends)
    axAll = findall(fig, 'Type', 'axes');
    isLegend = arrayfun(@(a) strcmp(get(a, 'Tag'), 'legend'), axAll);
    axAll(isLegend) = [];

    if numel(axAll) < 3
        warning('P%d: Less than 3 axes found, skipping.', p);
        close(fig);
        continue;
    end

    % Sort axes by Position to recover tile order:
    % top row first (higher y), then left-to-right (smaller x).
    pos = cat(1, axAll.Position);  % [x y w h]
    [~, idxSort] = sortrows([-pos(:,2), pos(:,1)]);
    axSorted = axAll(idxSort);

    % Tile 3 is the third axes in this sorted list
    ax3 = axSorted(3);

    % Get line objects from tile 3
    lines = findall(ax3, 'Type', 'line');

    tile3Data(p).folder = folderName;
    tile3Data(p).lines  = struct([]);

    for j = 1:numel(lines)
        tile3Data(p).lines(j).X           = get(lines(j), 'XData');
        tile3Data(p).lines(j).Y           = get(lines(j), 'YData');
        tile3Data(p).lines(j).DisplayName = get(lines(j), 'DisplayName');
    end

    close(fig);
end

%% ------------------ BUILD BIG 4x3 TILED FIGURE ------------------
close all
bigFig = figure('Color', 'w');
nRows  = 4;
nCols  = 3;

tBig = tiledlayout(nRows, nCols, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

for p = 1:nSubjects
    nexttile;
    hold on; %grid on;

    % Safety check
    if p > numel(tile3Data) || isempty(tile3Data(p).lines)
        title(sprintf('Subject left P%d (no data)', p), ...
            'FontName', 'Times New Roman', 'FontSize', 12, 'FontWeight','normal');
        xlabel('Epoch', 'FontName', 'Times New Roman', 'FontSize', 14);
        ylabel('Loss',  'FontName', 'Times New Roman', 'FontSize', 14);
        box on;
        continue;
    end

    lData  = tile3Data(p).lines;
    nLines = numel(lData);

    % Plot all lines in this tile and keep handles
    hLines = gobjects(1, nLines);
    for j = 1:nLines
        hLines(j) = plot(lData(j).X, lData(j).Y, 'LineWidth', 1.2);
        if ~isempty(lData(j).DisplayName)
            hLines(j).DisplayName = lData(j).DisplayName;
        end
    end

    % ----- Identify validation and training curves -----
    % Use DisplayName if available: look for 'val' and 'train'
    dispNames = strings(1, nLines);
    for j = 1:nLines
        if ~isempty(lData(j).DisplayName)
            dispNames(j) = string(lower(lData(j).DisplayName));
        else
            dispNames(j) = "";
        end
    end

    idxVal = find(contains(dispNames, "val"), 1);    % validation
    idxTr  = find(contains(dispNames, "train"), 1);  % training

    % Fallbacks if names aren't set
    if isempty(idxVal)
        if nLines >= 2
            idxVal = 2;
        else
            idxVal = 1;
        end
    end
    if isempty(idxTr)
        idxTr = 1;
    end

    % Extract validation data and find minimum
    xVal = lData(idxVal).X;
    yVal = lData(idxVal).Y;

    [valMin, idxMin] = min(yVal);
    epochMin = xVal(idxMin);

    % Extract training data
    xTr = lData(idxTr).X;
    yTr = lData(idxTr).Y;

    % Match training index by epoch (nearest)
    [~, idxTrNearest] = min(abs(xTr - epochMin));
    trainAtMin = yTr(idxTrNearest);

    % ----- Highlight minimum validation point with * -----
    hVal = hLines(idxVal);
    valColor = get(hVal, 'Color');
    plot(epochMin, valMin, '*', 'MarkerSize', 8, 'LineWidth', 1.5, ...
        'Color', valColor);

    % ----- Legend (no box) -----
    leg = legend(hLines, 'Location', 'north', 'Orientation','horizontal');
    set(leg, 'Box', 'off', 'FontName', 'Times New Roman', 'FontSize', 14);

    % ----- Titles, labels, box -----
    title(sprintf('Subject left P%d', p), ...
        'FontName', 'Times New Roman', 'FontSize', 12,'FontWeight','normal');
    xlabel('Epoch', 'FontName', 'Times New Roman', 'FontSize', 14);
    ylabel('Loss',  'FontName', 'Times New Roman', 'FontSize', 14);
    box on;

    % ----- Store summary info for this fold (numeric, 2 significant digits) -----
    looSummary(p).folder            = tile3Data(p).folder;
    looSummary(p).subjectIndex      = p;
    looSummary(p).epochMinVal       = epochMin;
    looSummary(p).trainLossAtMinVal = round(trainAtMin,  2, 'significant');
    looSummary(p).valLossMin        = round(valMin,      2, 'significant');

    % ----- Store FULL curves explicitly (numeric) -----
    looLossFull(p).folder       = tile3Data(p).folder;
    looLossFull(p).subjectIndex = p;

    % Use validation X as epoch if equal-sized and close; otherwise keep both
    % Here we'll simply store training & validation vs their own X:
    looLossFull(p).epoch_train = xTr;
    looLossFull(p).trainLoss   = yTr;
    looLossFull(p).epoch_val   = xVal;
    looLossFull(p).valLoss     = yVal;
end

% Set global font for all axes
allAx = findall(bigFig, 'Type', 'axes');
set(allAx, 'FontName', 'Times New Roman', 'FontSize', 14);

sgtitle('Leave one out training losses for each fold', ...
    'FontName', 'Times New Roman', 'FontSize', 14, 'FontWeight', 'bold');

%% ------------------ SAVE DATA TO MAT FILE ------------------
save(outMat, 'tile3Data', 'looSummary', 'looLossFull');
fprintf('Saved tile 3 data, LOO summary, and full loss curves to: %s\n', outMat);
%%
%% -------- BUILD TABLE OF BEST EPOCH AND LOSSES FOR ALL 11 SUBJECTS -----%% -------- BUILD TABLE OF BEST EPOCH AND LOSSES FOR ALL 11 SUBJECTS -----

% Extract numeric vectors from looSummary
subjects      = [looSummary.subjectIndex]';        % column vector
bestEpoch     = [looSummary.epochMinVal]';
trainLossBest = [looSummary.trainLossAtMinVal]';
valLossBest   = [looSummary.valLossMin]';

% Per-subject table (all numeric except Subject which is integer)
Tsub = table(subjects, bestEpoch, trainLossBest, valLossBest, ...
    'VariableNames', {'Subject','BestEpoch','TrainLoss','ValLoss'});

% ---------- Compute overall stats (median, min, max) ----------
medianEpoch     = median(bestEpoch);
medianTrainLoss = median(trainLossBest);
medianValLoss   = median(valLossBest);

minEpoch        = min(bestEpoch);
maxEpoch        = max(bestEpoch);

minTrainLoss    = min(trainLossBest);
maxTrainLoss    = max(trainLossBest);

minValLoss      = min(valLossBest);
maxValLoss      = max(valLossBest);

% Stats table: rows = Median, Min, Max (as strings), numeric columns
StatName  = ["Median"; "Min"; "Max"];

BestEpochStats = [medianEpoch;  minEpoch;  maxEpoch];
TrainLossStats = [medianTrainLoss; minTrainLoss; maxTrainLoss];
ValLossStats   = [medianValLoss;   minValLoss;   maxValLoss];

Tstats = table(StatName, BestEpochStats, TrainLossStats, ValLossStats, ...
    'VariableNames', {'Stat','BestEpoch','TrainLoss','ValLoss'});

% -------- WRITE BOTH TABLES TO A SINGLE CSV FILE -------------
csvFile = fullfile(rootDir, 'LOO_LossSummary.csv');

% 1) Write subject-wise table
writetable(Tsub, csvFile);

% 2) Append a blank line
fid = fopen(csvFile,'a');
fprintf(fid, '\n');
fclose(fid);

% 3) Append stats table (with its own header)
writetable(Tstats, csvFile, 'WriteMode','append');

fprintf('CSV summary table written to:\n%s\n', csvFile);

