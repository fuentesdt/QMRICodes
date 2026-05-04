%% Load per-patient 3D volumes (6 variables), process, and save a mask (NIfTI .nii.gz)
% Robust to numeric/text PatientIDs; uses char paths for niftiinfo/niftiread.

clc; clear; close all;

%% === USER SETTINGS ===
excelFile    = 'C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\acq_params.xlsx';
sheetName    = 1;                 % or a sheet name, e.g., 'Sheet1'
pidColName   = 'PatientID';       % Excel column with folder names (numeric OK)
baseDir      = 'C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\';
zeroPadWidth = 0;                 % set >0 if folders are zero-padded IDs (e.g., 6)

% Expected files on disk  -> variable name to create
filespec = {
    'PREOP_T1_W_S.nii.gz',   'T1w';
    'PREOP_AxT2_W_S.nii.gz', 'T2w';
    'PREOP_FLAIR_W_S.nii.gz','FLAIR';
    'pdmap.nii.gz',          'PD';
    't1map.nii.gz',          'T1';
    't2map.nii.gz',          'T2'
    };

%% === READ EXCEL ROBUSTLY (treat PatientID as text) ===
opts = detectImportOptions(excelFile, 'Sheet', sheetName, 'PreserveVariableNames', true);
if any(strcmpi(opts.VariableNames, pidColName))
    opts = setvartype(opts, pidColName, 'string'); % read as string to preserve exact form
else
    error('Column "%s" not found in %s.', pidColName, excelFile);
end
T = readtable(excelFile, opts);
pidVals = T.(pidColName);
nPat    = height(T);

% Helper: convert ID (numeric or string) to folder name, with optional zero-padding
idToFolder = @(x) local_id_to_folder(x, zeroPadWidth);

for i = 1:nPat
    pidStr     = idToFolder(pidVals(i));      % string
    patientDir = fullfile(baseDir, char(pidStr));  % ensure char

    fprintf('\n[%d/%d] Patient %s\n', i, nPat, char(pidStr));
    if ~isfolder(patientDir)
        warning('  Folder not found: %s', patientDir);
        continue;
    end

    % ---- Clear per-patient variables to avoid carry-over ----
    clear T1w T2w FLAIR PD T1 T2 refInfo
    tmpFilesToDelete = {};  % cell array of temp paths to delete later

    % ---- Load the six volumes into six separate variables ----
    for k = 1:size(filespec,1)
        fOnDisk = filespec{k,1};
        vName   = filespec{k,2};

        fpath = fullfile(patientDir, fOnDisk);   % char path
        if ~isfile(fpath)
            warning('  Missing: %s', fpath);
            continue;
        end

        try
            [img, info, tmpUnz] = local_read_nifti_any(fpath);
            % Assign to the correct variable
            switch vName
                case 'T1w',   T1w   = img;
                case 'T2w',   T2w   = img;
                case 'FLAIR', FLAIR = img;
                case 'PD',    PD    = img;
                case 'T1',    T1    = img;
                case 'T2',    T2    = img;
            end
            if ~exist('refInfo','var'), refInfo = info; end  % keep first loaded as reference
            if ~isempty(tmpUnz), tmpFilesToDelete{end+1} = tmpUnz; end
            fprintf('  Loaded %-26s -> %s  [%dx%dx%d]\n', ...
                fOnDisk, vName, size(img,1), size(img,2), size(img,3));

        catch ME
            warning('  Failed to read %s\n  %s', fpath, ME.message);
        end
    end

    % ---- If nothing loaded, skip cleanly ----
    if ~exist('refInfo','var')
        warning('  No volumes loaded for %s — skipping.', char(pidStr));
        local_cleanup_tmp(tmpFilesToDelete);
        continue;
    end

    % ---- Verify all six variables exist before processing ----
    haveAll = all(ismember({'T1w','T2w','FLAIR','PD','T1','T2'}, who));
    if ~haveAll
        warning('  Skipping processing: not all six volumes were loaded for %s.', char(pidStr));
        local_cleanup_tmp(tmpFilesToDelete);
        continue;
    end

    % ============================================================
    % =============== YOUR PROCESSING GOES RIGHT HERE ============
    % Replace the example below with your real processing that
    % uses T1w, T2w, FLAIR, PD, T1, T2 (each 3D arrays).
    T1w = double(T1w); T2w = double(T2w); FLAIR = double(FLAIR);



    % Toy example mask: bright on FLAIR and T2w, not bright on T1w
    mask = (FLAIR > 0) & (T2w > 0) & (T1w > 0) & (PD > 0) & (T1 > 0) & (T2 > 0);

    % Initial mask from all 6 volumes
    mask = (FLAIR > 0) & (T2w > 0) & (T1w > 0) & (PD > 0) & (T1 > 0) & (T2 > 0);

    % ---- Fill holes in 3D mask ----
    if ndims(mask) == 3
        % Fill slice-by-slice (common in medical images)
        for z = 1:size(mask,3)
            mask(:,:,z) = imfill(mask(:,:,z), 'holes');
        end
    else
        % 2D mask case
        mask = imfill(mask, 'holes');
    end



    % ---- Save mask as NIfTI (.nii.gz) alongside patient data ----
    outPath = fullfile(patientDir, 'mask.nii.gz');  % or [char(pidStr) '_mask.nii.gz']
    outInfo = refInfo;
    outInfo.Datatype = 'uint8';
    outInfo.BitDepth = 8;

    % niftiwrite wants the filename without ".gz" when using 'Compressed', true
    fnNoGz = outPath;
    if endsWith(fnNoGz, '.gz', 'IgnoreCase', true), fnNoGz = fnNoGz(1:end-3); end
    niftiwrite(uint8(mask), fnNoGz, outInfo, 'Compressed', true);
    fprintf('  Saved mask -> %s\n', outPath);

    % ---- Clean temp files (if any) ----
    local_cleanup_tmp(tmpFilesToDelete);
end

disp('All done.');

%% ================= LOCAL FUNCTIONS =================
function s = local_id_to_folder(x, padWidth)
% Convert numeric or string ID to folder name string, with optional zero-padding.
if ismissing(x)
    s = "";
    return;
end
if isnumeric(x)
    if mod(x,1)==0
        s = compose("%d", x);   % integer formatting (avoids 2.4305e+06)
    else
        s = string(x);
    end
else
    s = string(x);
end
if padWidth > 0
    s = pad(s, padWidth, 'left', '0');
end
end

function [img, info, tmpUnzNii] = local_read_nifti_any(fp)
% Read .nii or .nii.gz robustly. Always call nifti* with char paths.
% Returns img, info, and tmpUnzNii (path to temp unzipped .nii to delete), or ''.
tmpUnzNii = '';
if ~ischar(fp), fp = char(fp); end

try
    info = niftiinfo(fp);     % char path
    img  = niftiread(info);
    return
catch ME
    % If it's gz, unzip and try again
    if endsWith(fp, '.gz', 'IgnoreCase', true)
        tmpDir = tempname; mkdir(tmpDir);
        gunzip(fp, tmpDir);

        % Guess unzipped name by trimming '.gz'
        guess = fp(1:end-3);  % remove .gz
        [~, base, ext] = fileparts(guess); % ext is '.nii' expected
        if isfile(fullfile(tmpDir, [base ext]))
            unz = fullfile(tmpDir, [base ext]);
        else
            d = dir(fullfile(tmpDir, '*.nii'));
            if isempty(d)
                error('Unzipped NIfTI not found for %s', fp);
            end
            unz = fullfile(d(1).folder, d(1).name);
        end

        if ~ischar(unz), unz = char(unz); end
        info = niftiinfo(unz);
        img  = niftiread(info);
        tmpUnzNii = unz;  % remember to delete later
    else
        rethrow(ME);
    end
end
end

function local_cleanup_tmp(tmpPaths)
% Delete temporary unzipped files and their folders safely.
if isempty(tmpPaths), return; end
for ii = 1:numel(tmpPaths)
    p = tmpPaths{ii};
    if isempty(p), continue; end
    try
        if isfile(p), delete(p); end
        f = fileparts(p);
        if isfolder(f), rmdir(f, 's'); end
    catch
        % ignore cleanup errors
    end
end
end