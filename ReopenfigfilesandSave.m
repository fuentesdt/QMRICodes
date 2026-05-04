%% ================================================================
% Open saved .fig files for all PatientIDs and re-save as .png
% with the same base file name
% ================================================================

clear; clc; close all;

%% ---------------------- PATHS -----------------------------------
rootDir   = pwd;
excelName = 'acq_params.xlsx';

outDir = fullfile(rootDir, 'ManuscriptResultsBigR2');
if ~exist(outDir,'dir')
    error('Output directory not found: %s', outDir);
end

%% ---------------------- READ PATIENT IDS ------------------------
T = readtable(fullfile(rootDir, excelName), 'VariableNamingRule','preserve');

pidCol = find(strcmpi(T.Properties.VariableNames, 'PatientID'), 1);
if isempty(pidCol)
    pidCol = 1; % fallback
end

PatientID = string(T{:, pidCol});
PatientID = PatientID(~ismissing(PatientID));
N = numel(PatientID);

fprintf('[Info] Found %d patients from %s\n', N, excelName);

%% ---------------------- FILE PATTERNS ---------------------------
% figPatterns = { ...
%     'Figure1A_Qualitative_%s_QmapsBW.fig', ...
%     'Figure1A_Qualitative_%s_QmapsCLR.fig', ...
%     'Figure1B_Qualitative_%s_SigBW.fig', ...
%     'Figure1B_Qualitative_%s_SigCLR.fig'};
% figPatterns = {'Figure2_ScatterDensityPatient_%s.fig'};

figPatterns = {'Figure_Histogram_%s_QmapsSignals.fig'};

dpi = 300;

%% ---------------------- OPEN + SAVE PNG -------------------------
for p = 1:N
    pid = PatientID(p);

    for k = 1:numel(figPatterns)
        figName = sprintf(figPatterns{k}, pid);
        figPath = fullfile(outDir, figName);

        if ~exist(figPath, 'file')
            fprintf('[Missing] %s\n', figName);
            continue;
        end

        fprintf('[Open] %s\n', figName);

        % Open .fig invisibly
        h = openfig(figPath, 'invisible');

        % Build PNG path with same base file name
        [~, baseName, ~] = fileparts(figName);
        pngPath = fullfile(outDir, baseName + ".png");

        % Save as PNG
        print(h, pngPath, '-dpng', sprintf('-r%d', dpi));

        % Close figure
        close(h);

        fprintf('[Saved] %s\n', pngPath);
    end
end

fprintf('\nDone. All available .fig files were exported to PNG in:\n%s\n', outDir);