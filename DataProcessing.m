%% Load NIfTI files per patient from Excel-driven folder list
% Works when patient IDs are numeric or text. Supports optional zero-padding.

clc; clear; close all;

%% === USER SETTINGS ===
excelFile   = "C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\acq_params.xlsx";   % <-- update path
sheetName   = 1;                     % or sheet name
pidColName  = "PatientID";           % <-- Excel column with patient IDs (folder names)
baseDir     = "C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\"; % <-- update base folder
zeroPadWidth = 0; % <- set e.g. 6 if your folder names are zero-padded like 000123

% Expected files (name on disk -> field name to store)
filespec = {
    "PREOP_T1_W_S.nii.gz",     "T1w";
    "PREOP_AxT2_W_S.nii.gz",   "T2w";
    "PREOP_FLAIR_W_S.nii.gz",  "FLAIR";
    "pdmap.nii.gz",            "PD";
    "t1map.nii.gz",            "T1";
    "t2map.nii.gz",            "T2"
};

%% === READ EXCEL (treat patientID robustly) ===
opts = detectImportOptions(excelFile, 'Sheet', sheetName, 'PreserveVariableNames', true);
% If the column exists, force it to string so we preserve any formatting if present:
if any(strcmpi(opts.VariableNames, pidColName))
    opts = setvartype(opts, pidColName, 'string');
else
    error('Column "%s" not found in %s.', pidColName, excelFile);
end
T = readtable(excelFile, opts);

pidVals = T.(pidColName); % string array (or may still come as numeric if Excel forced it)
nPat    = height(T);

%% === Helper to turn an ID (numeric or string) into a folder name ===
idToFolder = @(x) local_id_to_folder(x, zeroPadWidth);

%% === Loop patients ===
patientData = repmat(struct( ...
    'pid', "", ...
    'dir', "", ...
    'loaded', struct() ...
), nPat, 1);

for i = 1:nPat
    % Convert to string safely (handles numeric or string)
    pidStr = idToFolder(pidVals(i));
    patientDir = fullfile(baseDir, pidStr);

    patientData(i).pid = pidStr;
    patientData(i).dir = patientDir;
    fprintf('\n[%d/%d] Patient %s\n', i, nPat, pidStr);

    if ~isfolder(patientDir)
        warning('  Folder not found: %s', patientDir);
        continue;
    end

    % For each expected file
    for k = 1:size(filespec,1)
        fname   = filespec{k,1};
        outName = filespec{k,2};
        fpath   = fullfile(patientDir, fname);

        if ~isfile(fpath)
            warning('  Missing: %s', fpath);
            continue;
        end

        try
            [img,info] = local_read_nifti(fpath);
            patientData(i).loaded.(outName).img  = img;
            patientData(i).loaded.(outName).info = info;
            fprintf('  Loaded %-26s -> %s\n', fname, outName);
        catch ME
            warning('  Failed to read %s\n  %s', fpath, ME.message);
        end
    end
end

disp('Done loading.');

%% ====== LOCAL FUNCTIONS ======
function s = local_id_to_folder(x, padWidth)
    % Convert numeric or string ID to folder name string, with optional zero-padding.
    if ismissing(x)
        s = "";
        return;
    end
    if isnumeric(x)
        s = string(x); % or compose("%d", x) to avoid scientific notation
        % prefer integer formatting to be safe:
        if mod(x,1)==0
            s = compose("%d", x);
        else
            % if Excel had decimals (unlikely for IDs), keep full value
            s = string(x);
        end
    else
        s = string(x);
    end
    if padWidth > 0
        % Left pad with zeros if requested
        s = pad(s, padWidth, 'left', '0');
    end
end

function [img, info] = local_read_nifti(fp)
    % Read .nii or .nii.gz using built-in functions; fall back to gunzip if needed.
    try
        info = niftiinfo(fp);
        img  = niftiread(info);
    catch
        if endsWith(fp, ".gz", 'IgnoreCase', true)
            tmpDir = tempname;
            mkdir(tmpDir);
            gunzip(fp, tmpDir);
            unz = fullfile(tmpDir, erase(string(fp), ".gz"));
            % gunzip may strip only the ".gz" — ensure correct path exists:
            % If that fails, try detecting the unzipped file in tmpDir.
            if ~isfile(unz)
                d = dir(fullfile(tmpDir, '*.nii'));
                if isempty(d)
                    error('Could not locate unzipped NIfTI for %s', fp);
                end
                unz = fullfile(d(1).folder, d(1).name);
            end
            info = niftiinfo(unz);
            img  = niftiread(info);
        else
            rethrow(lasterror); 
        end
    end
end