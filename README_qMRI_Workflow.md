qMRI 3D CNN Workflow: User Guide
##################################

Project Structure
-----------------
- /rsrch1/ip/mnandyala/Desktop/hwang_cases/ProcessedData
  → Original patient data (folders named using real Patient IDs)

- /rsrch1/ip/mnandyala/Desktop/hwang_cases/ProcessedData2
  → Anonymized data (folders named P0001, P0002, ... It is the same data as above)
  → Includes Excel mapping anonymized IDs to real IDs

Each root folder contains:
- Patient subfolders
- Excel file with acquisition parameters (acq_params.xlsx)

--------------------------------------------------
STEP 1 — TRAINING
--------------------------------------------------

Option A: Train using ALL patients
File:
run_qmri_3dcnn_NonNormalSingalAllPatientsTraining.m

For more details, read the file "readme_ run_qmri_3dcnn_NonNormalSingalAllPatientsTraining.txt"

- Loads acq_params.xlsx
- Uses all patients
- Saves model in:
  trained_models_All/

--------------------------------------------------

Option B: Leave-One-Patient-Out (LOPO)

Manual version:
run_qmri_3dcnn_NonNormalSingalLeaveOneOutTraining.m

For more details, read the file "readme_run_qmri_3dcnn_NonNormalSingalLeaveOneOutTraining.txt"

Requires Excel files:
acq_paramsP1.xlsx, acq_paramsP2.xlsx, ...

Outputs:
trained_models_P1/, trained_models_P2/, ...

--------------------------------------------------

Recommended Automatic version:
run_qmri_3dcnn_NonNormalSingalLeaveOneOutTraining_Automatic.m

- No need to create multiple Excel files
- Automatically excludes one patient
- Uses acq_params.xlsx

Outputs:
trained_models_LeftOut_PID1/
trained_models_LeftOut_PID2/
...
PIDs are same as listed in the Excel file
--------------------------------------------------
STEP 2 — PREDICTION
--------------------------------------------------

Case 1: Manual Prediction
File:
predict_qmri_3dcnn_NonNormalSignal.m

For more details read the file "readme_predict_qmri_3dcnn_NonNormalSignal.txt"

Steps:
1. Select trained model
2. Select Excel file
3. Select root directory
4. Set savedir manually

Outputs:
PatientID/YourOutputFolder/
YourOutputFolder needs to be manually set everytime: example P1L1OutPred for predcitions using the network trained exclding P1.
P1L1OutPred: P1 Excluded
P2L1OutPred: P2 Excluded
P3L1OutPred: P3 Excluded

This code makes predictions for all the patients (Held out + In-train) for the selected trained network.
--------------------------------------------------

Case 2: Automated LOPO (Non-anonymized)
File:
predict_qmri_3dcnn_NonNormalSignal_Automated.m

- Uses trained_models_PX folders
- Detects left-out patient from Excel order
- Prompts for prediction mode: 
    It asks for whether to make predictions for only held-out patient or all the patients
- Supports trained_models_all → All_Pred

Outputs:
PatientID/PXL1OutPred/
P1L1OutPred: P1 Excluded
P2L1OutPred: P2 Excluded
P3L1OutPred: P3 Excluded
--------------------------------------------------

Case 3: Automated (Anonymized) — Recommended
File:
predict_qmri_3dcnn_NonNormalSignal_AutomatedAnonymizedFolders.m

- Uses trained_models_LeftOut_P0001 format
- Extracts PatientID directly from folder name
- Supports trained_models_all → All_Pred
- Prompts for prediction mode: 
    It asks for whether to make predictions for only held-out patient or all the patients

Outputs:
P0001_Left_Predictions/
P0002_Left_Predictions/
All_Pred/

--------------------------------------------------
CORE PROCESS (COMMON)
--------------------------------------------------

- Load T1w, T2w, FLAIR
- Load acquisition parameters
- Construct input structure
- Run 3D CNN (sliding window)
- Predict PD, T1, T2, g1, g2, g3
- Synthesize MRI signals
- Save outputs and metrics

--------------------------------------------------
RECOMMENDED WORKFLOW (5-fold CV on the anonymized CSV cohort)
--------------------------------------------------

The two recommended scripts now run 5-fold cross-validation over the anonymized
MAGiC cohort indexed by a CSV (schema in doc/fulldataset.md), instead of LOPO
over acq_params.xlsx. Patients are grouped by AnonymizationID into 5 folds.

The inputs in the CSV are DICOM, so a Python/SimpleITK preprocessing step
converts them to NIfTI under processed/<AnonymizationID>/ first:
- T1W/T2W/FLAIR Synthetic : one DICOM series each -> T1W/T2W/FLAIR.nii.gz
- SYMAPS : a directory of per-slice DICOM files named SYMAPS_<NN>_{T1,T2,PD}.dcm,
  split by suffix into the quantitative reference maps T1map/T2map/PD.nii.gz
- PS Synthetic (if present) : converted to PS.nii.gz (not used by the pipeline)

Acquisition parameters (TR/TE/FA/TI) are read per patient from the NIfTI header
'descrip' field (MATLAB niftiinfo().Description), which the preprocessor stamps
from each weighted contrast's DICOM (RepetitionTime/EchoTime/FlipAngle/InversionTime).
config.acq is only an optional fallback for tags a header happens to lack.

Python setup (one time), for the preprocessing step:
   python3 -m venv /opt/qmricodes
   /opt/qmricodes/bin/pip install -r requirements.txt
Then invoke the preprocessor with that interpreter, e.g.
   /opt/qmricodes/bin/python3 preprocess_dicom_to_nifti.py ...

0. Preprocess (run once, before MATLAB), converts DICOM -> processed/<id>/*.nii.gz
   and stamps the acq tags into each NIfTI header:
     /opt/qmricodes/bin/python3 preprocess_dicom_to_nifti.py --csv dataset.csv --out processed
   Add --require-matched to convert only rows with a valid match_status.

   If the SYMAPS maps and the weighted contrasts were exported on different voxel
   grids (MATLAB will error "Size mismatch ..."), add --resample. It mirrors each
   patient onto the T1W input grid in a SEPARATE directory (default
   processed_resampled/): volumes whose grid differs are linearly resampled, the
   rest are copied. Then set config.processedRoot to that *_resampled directory.
     /opt/qmricodes/bin/python3 preprocess_dicom_to_nifti.py --csv dataset.csv --out processed --resample

Before running the MATLAB scripts, edit the CONFIG block at the top of each:
- config.csvName : cohort CSV filename in the root folder (default dataset.csv)
- config.processedRoot : preprocessor output (default <rootDir>/processed)
- config.useRefMaps : true = supervised on SYMAPS T1/T2/PD maps (default);
                      false = signal-only (physics loss on weighted images alone)
- config.requireMatched : keep only rows with a valid match_status
- config.outRoot : where per-patient outputs are written

1. Train using:
   run_qmri_3dcnn_NonNormalSignalLeaveOneOutTraining_Automatic.m
   - Reads config.csvName, assigns 5 folds, writes the PHI-free manifest
     cv_folds.csv (AnonymizationID,fold), and saves one model per fold in
     trained_models_Fold1/ ... trained_models_Fold5/.

2. Predict using:
   predict_qmri_3dcnn_NonNormalSignal_AutomatedAnonymizedFolders.m
   - Select a trained_models_Fold<f> model; the script reads cv_folds.csv and
     predicts that fold's held-out patients (set config.predictAll=true for all).
   - Outputs go to <outRoot>/<AnonymizationID>/Fold<f>_Predictions/.

PHI PROTECTION (see ../radpathsandbox/CLAUDE.md):
Only AnonymizationID is ever printed or used in file/folder names. MRN, Study
UID, and Series UID are never logged or written. Every required input file is
gated by requireFile() (fail fast) before it is read. cv_folds.csv contains only
AnonymizationID and fold number.

--------------------------------------------------
NOTES
--------------------------------------------------

- Patient folder names must match Excel PatientID
- Excel must include TR, TE, FA, TI

Other code file needed for Post-processing of the predictions to plot the figures.
- TrainingAndValidationLossDataExtractor.m 
  This file loads the the training and validation
  figures during the training for each fold and puts them together.
- ManuscriptPlotsGenerationCode.m
  This file loads the held-out and intrain predicted maps (Outputs of the prediction code) and plot the figures in .fig, .png, .pdf format. Use server to run this code.
- ReopenfigfilesandSave.m 
  This file loads the .fig files created by the previous code and saves them again in .fig and .png format. The .fig plot created using the ManuscriptPlotsGenerationCode.m on the server are not clean so this is additional step to get the clean plots.

There are some additional matlab codes which were used for some data processing/saving the files in required naming.
