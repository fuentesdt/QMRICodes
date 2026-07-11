# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MATLAB research code for **physics-guided quantitative MRI (qMRI) parameter mapping**. A 3D U-Net takes three routine structural contrasts (T1w, T2w, FLAIR) as input and predicts six maps — PD, T1, T2, and three signal-gain terms g1/g2/g3. The key idea: predicted maps are pushed back through MR signal equations (SPGR/GRE, spin-echo, inversion-recovery) to re-synthesize the input images, and the loss compares synthesized-vs-measured signal plus an L1 term against reference SyMRI/MAGiC maps. There is no build system, package manager, or test suite — scripts are run interactively from within MATLAB.

## Running (no CLI, no tests)

Requires MATLAB with **Deep Learning Toolbox** + **Image Processing Toolbox** (Signal Processing Toolbox optional; GPU auto-detected via `canUseGPU`). Run scripts from within MATLAB with the current folder set to the data root — every script uses `config.rootDir = pwd` and expects `acq_params.xlsx` plus patient subfolders there. Prediction scripts pick model/Excel/root via `uigetfile`/`uigetdir` dialogs.

Recommended end-to-end workflow (see `README_qMRI_Workflow.md`):
1. Train (LOPO, auto): `run_qmri_3dcnn_NonNormalSignalLeaveOneOutTraining_Automatic.m` → writes `trained_models_LeftOut_<PID>/`
2. Predict: `predict_qmri_3dcnn_NonNormalSignal_AutomatedAnonymizedFolders.m` → writes `<PID>/<savedir>/*_pred.nii.gz`
3. Figures: `ManuscriptPlotsGenerationCode.m` (run on a server), then `ReopenfigfilesandSave.m` to re-export clean `.fig`/`.png`.

## Architecture

**Script-oriented with heavy duplication, not a shared library.** Each runnable `.m` inlines its own copies of helpers (`readNii`, `pickVar`, `matchExisting`, `synthSignals`, `sigmoid`, `normalizeContrasts`, …). When fixing a helper, expect to change it in several files. The only genuinely shared function is `ccc_barnes.m` (concordance correlation coefficient, the primary agreement metric). Coupling between scripts is by **data flow on disk**, not function calls:

    training scripts → trained_models_*/{best_epoch.mat, epochNNN.mat, LossesFigure.fig}
      → prediction scripts consume the .mat (net + config) → <PID>/<savedir>/*_pred.nii.gz + Comparison.fig + TestLosses.mat
        → ManuscriptPlotsGenerationCode.m consumes prediction outputs → ReopenfigfilesandSave.m re-exports its .fig
    TrainingAndValidationLossDataExtractor.m consumes the training LossesFigure.fig files

The core model + training loop lives in local functions of the training scripts (`buildUNet3D`, `extractPatches3D`, `makeMinibatchQueue`, `modelGradients`, `synthSignals`, `adamw_step`, `cosineLR`). Prediction scripts re-implement these plus `slidingPredict` (sliding-window inference with Gaussian blending). Output ranges are hard-capped via scaled sigmoid (PD≤150, T1≤5000 ms, T2≤3000 ms, g≤500). The `config` struct (patch size, caps, hyperparameters) is saved inside every model `.mat` so prediction can reconstruct inference settings.

Script groups:
- **Training**: `run_qmri_3dcnn_NonNormalSignalAllPatientsTraining.m` (all patients → `trained_models_All/`), `...LeaveOneOutTraining.m` (manual LOPO, needs `acq_paramsP1.xlsx`, `acq_paramsP2.xlsx`, …), `...LeaveOneOutTraining_Automatic.m` (recommended; loops folds from one `acq_params.xlsx`).
- **Prediction**: `predict_qmri_3dcnn_NonNormalSignal.m` (manual), `..._Automated.m`, `..._AutomatedAnonymizedFolders.m` (recommended).
- **Post-processing**: `ManuscriptPlotsGenerationCode.m`, `TrainingAndValidationLossDataExtractor.m`, `ReopenfigfilesandSave.m`.
- **Data prep / utilities**: `DataProcessing.m`, `DataProcessingIndPatient.m`, `ConvertPatientDatatoCSV.m`, `dicomLoaderAndViewer.m` (standalone DICOM viewer), `ccc_barnes.m`.

## Data conventions

- `acq_params.xlsx` must have a `PatientID` column plus acquisition params `TRT1, TET1, FAT1_deg, TRT2, TET2, TRFLAIR, TEFLAIR, TIFLAIR`. Column names are alias-resolved via the repeated `pickVar` helper (`TR_T1`, `TR_Gre`, `TR_SPGR`, …).
- **Patient folder names must equal the `PatientID`.** Per-folder files: inputs `PREOP_T1_W_S.nii.gz`, `PREOP_AxT2_W_S.nii.gz`, `PREOP_FLAIR_W_S.nii.gz`; references `pdmap.nii.gz`, `t1map.nii.gz`, `t2map.nii.gz`; optional `mask.nii.gz` (skull-stripped brain). All I/O is NIfTI.
- Two data roots referenced in docs: `ProcessedData` (real Patient IDs) and `ProcessedData2` (anonymized `P0001…`).

## Gotchas

- Several data-prep scripts have **hard-coded Windows absolute paths** (e.g. `C:\Users\MNandyala\...` in `ConvertPatientDatatoCSV.m`, `DataProcessing.m`) that must be edited before running elsewhere.
- One readme filename contains a literal space: `readme_ run_qmri_3dcnn_NonNormalSingalAllPatientsTraining.txt`.
- `README_qMRI_Workflow.md` and `.txt` are duplicate copies — keep them in sync if edited.
- TV / edge-aware regularizers (`tvCharb`, `l2smooth`, `computeEdgeWeights`) are implemented but currently commented out in the loss.
- `doc/fulldataset.md` describes an intended next step (run over a full PHI-indexed CSV dataset) and points to an external `../radpathsandbox/CLAUDE.md` PHI-protection workflow: never print/commit PHI data values — work with column names, dtypes, counts, and aggregate stats only.
