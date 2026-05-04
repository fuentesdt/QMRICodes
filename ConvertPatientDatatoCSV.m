rootDir = 'C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\'
xlsPath = 'C:\Users\MNandyala\Desktop\MDACC_Project\BrainProject\hwang_cases\ProcessedData\'
xlsFile = 'acq_params.xlsx'
T = readtable(fullfile(xlsPath, xlsFile));
% Resolve expected column names (robust aliases)
idCol   = pickVar(T, ["PatientID","ID","Subject","SubjectID"]);
TRT1col = pickVar(T, ["TRT1","TR_T1","TR_Gre","TR_SPGR","TR_T1w"]);
TET1col = pickVar(T, ["TET1","TE_T1","TE_Gre","TE_SPGR","TE_T1w"]);
FADcol  = pickVar(T, ["FAT1_deg","FA_deg","Flip_deg","FA","FlipAngle_deg"]);
TRT2col = pickVar(T, ["TRT2","TR_SE","TR_T2","TR_T2w"]);
TET2col = pickVar(T, ["TET2","TE_SE","TE_T2","TE_T2w"]);
TRFcol  = pickVar(T, ["TRFLAIR","TR_FLAIR","TR_IR"]);
TEFcol  = pickVar(T, ["TEFLAIR","TE_FLAIR"]);
TIFcol  = pickVar(T, ["TIFLAIR","TI","TI_FLAIR"]);

patientIDs = string(T.(idCol));
patientIDs = patientIDs(~ismissing(patientIDs) & strlength(patientIDs)>0);
%%
% Filter to IDs that exist as folders
valid = strings(0,1);
for i=1:numel(patientIDs)
    if isfolder(fullfile(rootDir, patientIDs(i)))
        valid(end+1) = patientIDs(i);
    end
end
assert(~isempty(valid), 'No patient subfolders matching Excel IDs found under: %s', rootDir);
%%
for sel = 1%:numel(valid)
    close all
    pid  = valid{sel};
    pdir = fullfile(rootDir, pid);
    fprintf('Selected patient: %s\n', pid);

    %%% 4) Locate & load patient data
    % === File name definitions for this dataset ===
    config.fileT1w   = "PREOP_T1_W_S.nii.gz";
    config.fileT2w   = "PREOP_AxT2_W_S.nii.gz";
    config.fileFLAIR = "PREOP_FLAIR_W_S.nii.gz";
    config.filePDref   = "pdmap.nii.gz";
    config.fileT1ref   = "t1map.nii.gz";
    config.fileT2ref   = "t2map.nii.gz";

    % === Locate patient files ===
    fileT1w   = matchExisting(pdir, [config.fileT1w, erase(config.fileT1w,".gz")]);  % handle .nii/.nii.gz
    fileT2w   = matchExisting(pdir, [config.fileT2w, erase(config.fileT2w,".gz")]);
    fileFLAIR = matchExisting(pdir, [config.fileFLAIR, erase(config.fileFLAIR,".gz")]);
    filePDref   = matchExisting(pdir, [config.filePDref, erase(config.filePDref,".gz")]);  % handle .nii/.nii.gz
    fileT1ref   = matchExisting(pdir, [config.fileT1ref, erase(config.fileT1ref,".gz")]);
    fileT2ref = matchExisting(pdir, [config.fileT2ref, erase(config.fileT2ref,".gz")]);
    fileMask  = matchExisting(pdir, ["mask.nii.gz","mask.nii"], true); % optional mask

    S1  = readNii(fullfile(pdir,fileT1w)); infoRef = niftiinfo(fullfile(pdir,fileT1w));
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

end
%% Local functions used
function name = pickVar(T, candidates)
% Return the first matching column name (case-insensitive)
for i=1:numel(candidates)
    if any(strcmpi(T.Properties.VariableNames, candidates(i)))
        name = candidates(i); return;
    end
end
error('Excel is missing required column. Tried any of: %s', strjoin(string(candidates),', '));
end
function file = matchExisting(folder, candidates, optional)
if nargin<3, optional=false; end
for i=1:numel(candidates)
    if isfile(fullfile(folder, candidates(i)))
        file = candidates(i); return;
    end
end
if optional, file = '';
else
    error('Missing required file in %s. Tried: %s', folder, strjoin(string(candidates),', '));
end
end