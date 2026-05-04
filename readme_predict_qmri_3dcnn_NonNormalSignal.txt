This MATLAB script performs inference using a trained qMRI 3D CNN model. It loads a trained 3D U-Net model, loads patient MRI data and acquisition parameters, runs sliding-window prediction over 3D MRI volumes, saves predicted quantitative maps as NIfTI files, synthesizes MRI signals from the predicted maps, and generates comparison plots and loss values.

The script is designed mainly for evaluating Leave-One-Patient-Out (LOPO) trained networks. For example, a model trained by leaving out Patient 1 can be used to generate predictions for all patients, where Patient 1 predictions are true held-out predictions and the remaining patient predictions are in-training predictions.

---

## 1. What the code does

The script:

1. Asks the user to select a trained `.mat` model file.
2. Loads the trained network variable `net` and, if available, the training `config`.
3. Asks the user to select an Excel file containing acquisition parameters for all patients.
4. Asks the user to select the root folder containing all patient subfolders.
5. Finds patient folders whose names match the `PatientID` values in the Excel file.
6. Loops through all valid patients.
7. Loads each patient’s T1w, T2w, FLAIR, PD, T1, T2, and optional mask files.
8. Runs sliding-window inference using the trained network.
9. Converts raw network outputs into physically bounded PD, T1, T2, g1, g2, and g3 maps.
10. Synthesizes T1w, T2w, and FLAIR signals from the predicted maps.
11. Computes test-style signal loss and parameter loss.
12. Computes concordance correlation coefficients (CCC) for predicted maps and synthesized signals.
13. Saves predicted maps, synthesized signals, loss values, and comparison plots inside each patient folder.

---

## 2. Purpose of `savedir`

At the beginning of the script, the output folder name is defined as:


savedir = "P1L1OutPred";


This folder name identifies which LOPO-trained model was used.

Example:


P1L1OutPred


means:


Model trained by leaving out Patient 1
Predictions generated using that model


For each patient, the script creates a subfolder with this name:


Patient_i/
└── P1L1OutPred/
    ├── PD_pred.nii.gz
    ├── T1_pred_ms.nii.gz
    ├── T2_pred_ms.nii.gz
    ├── g1_pred.nii.gz
    ├── g2_pred.nii.gz
    ├── g3_pred.nii.gz
    ├── T1w_calc.nii.gz
    ├── T2w_calc.nii.gz
    ├── FLAIR_calc.nii.gz
    ├── TestLosses.mat
    ├── Comparison.png
    └── Comparison.fig


Important interpretation:


For the left-out patient:
    Predictions are true held-out/generalization predictions.

For the other patients:
    Predictions are from a model that was trained using those patients.


---

## 3. Required trained model file

The script asks the user to manually select a `.mat` file.

The selected `.mat` file must contain:


net


It may also contain:


config
trainLoss
valLoss


The variable `net` is required. It is the trained 3D CNN.

The variable `config` is optional but recommended because the script uses it to read:


patchSize
PDmax
T1max
T2max
g1max
g2max
g3max
wSignal
lamPD
lamT1
lamT2


If these values are not available in `config`, some parts of the script may fail or print missing-bound messages.

---

## 4. Required Excel file

The script asks the user to manually select an Excel file containing acquisition parameters for all patients.

The Excel file must contain patient IDs and acquisition parameters.

The code accepts multiple possible column-name aliases.

### Patient ID column

Accepted names include:


PatientID
ID
Subject
SubjectID


### T1w acquisition columns

Accepted names include:


TRT1, TR_T1, TR_Gre, TR_SPGR, TR_T1w
TET1, TE_T1, TE_Gre, TE_SPGR, TE_T1w
FAT1_deg, FA_deg, Flip_deg, FA, FlipAngle_deg


### T2w acquisition columns

Accepted names include:


TRT2, TR_SE, TR_T2, TR_T2w
TET2, TE_SE, TE_T2, TE_T2w


### FLAIR acquisition columns

Accepted names include:


TRFLAIR, TR_FLAIR, TR_IR
TEFLAIR, TE_FLAIR
TIFLAIR, TI, TI_FLAIR


The final acquisition vector used by the code is:


TRT1
TET1
FAT1 in radians
TRT2
TET2
TRFLAIR
TEFLAIR
TIFLAIR


---

## 5. Required root folder structure

The script asks the user to select a root folder containing all patient folders.

The patient folder names must match the patient IDs in the Excel file.

Example:


ProjectRoot/
├── P1/
├── P2/
├── P3/
├── ...
└── P11/


If the Excel file contains:


PatientID
P1
P2
P3


then the folders must be:


P1/
P2/
P3/


The code filters the Excel patient list and only keeps IDs that exist as folders under the selected root directory.

---

## 6. Required files inside each patient folder

Each patient folder must contain these input MRI files:


PREOP_T1_W_S.nii.gz
PREOP_AxT2_W_S.nii.gz
PREOP_FLAIR_W_S.nii.gz


The script also loads reference qMRI maps:


pdmap.nii.gz
t1map.nii.gz
t2map.nii.gz


The mask file is optional:


mask.nii.gz


If `mask.nii.gz` is missing, the script uses the entire image volume as the mask.

The script can also accept uncompressed `.nii` versions of the same files.

For example, it can load either:


PREOP_T1_W_S.nii.gz


or:


PREOP_T1_W_S.nii


---

## 7. Input data format

The input MRI volumes are loaded as 3D NIfTI images.

The three structural MRI inputs are combined as:


Xfull = cat(4, S1, S2, S3);


So the network input has format:


[Z, Y, X, 3]


where:


Channel 1 = T1w
Channel 2 = T2w
Channel 3 = FLAIR


The NIfTI dimensions of T1w, T2w, FLAIR, and mask must match.

---

## 8. Sliding-window inference

The script does not predict the full 3D volume at once.

Instead, it uses sliding-window prediction.

The patch size is taken from the trained config if available:


patchSize = cfgTr.patchSize;


If not available, the default is:


64 × 64 × 64


The stride is set as:


stride = max(1, floor(patchSize/4));


For a patch size of 64 × 64 × 64, the stride becomes:


16 × 16 × 16


This creates overlapping patches.

The code uses Gaussian blending to combine patch predictions smoothly into a full-volume prediction.

---

## 9. Network outputs

The network produces 6 raw output channels:


Channel 1 = raw PD
Channel 2 = raw T1
Channel 3 = raw T2
Channel 4 = raw g1
Channel 5 = raw g2
Channel 6 = raw g3


These raw outputs are transformed using sigmoid scaling:


PD = PDmax × sigmoid(raw PD)
T1 = T1max × sigmoid(raw T1)
T2 = T2max × sigmoid(raw T2)
g1 = g1max × sigmoid(raw g1)
g2 = g2max × sigmoid(raw g2)
g3 = g3max × sigmoid(raw g3)


Typical expected bounds are:


PD: 0 to 150
T1: 0 to 5000 ms
T2: 0 to 3000 ms
g1: 0 to 500
g2: 0 to 500
g3: 0 to 500


After prediction, the code applies light 3D Gaussian smoothing with:


sigma = 0.1


Then all predictions outside the brain mask are set to zero.

---

## 10. Synthesized MRI signals

After predicting PD, T1, T2, g1, g2, and g3, the script synthesizes three MRI signals:


T1w_calc
T2w_calc
FLAIR_calc


The signal equations use:


T1w GRE/SPGR-type signal without T2*
T2w spin-echo-type signal
FLAIR inversion-recovery signal


These synthesized signals are compared with the measured input MRI images.

---

## 11. Losses computed during inference

The script computes a test loss using the same style as training:


TestLoss = Lsig + Lpar


### Signal loss

The signal loss compares measured input signals with synthesized signals:


T1w measured vs T1w_calc
T2w measured vs T2w_calc
FLAIR measured vs FLAIR_calc


### Parameter loss

The parameter loss compares predicted maps with reference qMRI maps:


PD_pred vs pdmap.nii.gz
T1_pred_ms vs t1map.nii.gz
T2_pred_ms vs t2map.nii.gz


The script saves:


TestLosses.mat


containing:


Lsig
Lpar
TestLoss
trainLoss
valLoss


---

## 12. Correlation and comparison plots

The script computes concordance correlation coefficient values for:


PD
T1
T2
T1w signal
T2w signal
FLAIR signal


It then creates a figure with six scatter plots:


Measured T1w vs synthesized T1w
Measured T2w vs synthesized T2w
Measured FLAIR vs synthesized FLAIR
Reference PD vs predicted PD
Reference T1 vs predicted T1
Reference T2 vs predicted T2


The figure is saved as:


Comparison.png
Comparison.fig


---

## 13. Output files saved for each patient

For each patient, the script saves outputs in:


PatientID/savedir/


For example:


P1/P1L1OutPred/


The saved predicted qMRI maps are:


PD_pred.nii.gz
T1_pred_ms.nii.gz
T2_pred_ms.nii.gz
g1_pred.nii.gz
g2_pred.nii.gz
g3_pred.nii.gz


The saved synthesized MRI signals are:


T1w_calc.nii.gz
T2w_calc.nii.gz
FLAIR_calc.nii.gz


The saved loss and plot files are:


TestLosses.mat
Comparison.png
Comparison.fig


---

## 14. Full expected output folder example

For `savedir = "P1L1OutPred"` and patient `P1`, the output becomes:


P1/
└── P1L1OutPred/
    ├── PD_pred.nii.gz
    ├── T1_pred_ms.nii.gz
    ├── T2_pred_ms.nii.gz
    ├── g1_pred.nii.gz
    ├── g2_pred.nii.gz
    ├── g3_pred.nii.gz
    ├── T1w_calc.nii.gz
    ├── T2w_calc.nii.gz
    ├── FLAIR_calc.nii.gz
    ├── TestLosses.mat
    ├── Comparison.png
    └── Comparison.fig


---


## 15. Important possible issues

### 15.1 Manual `savedir` must match the model

The user must manually update:


savedir = "P1L1OutPred";


when using a different LOPO-trained model.

For example:


P2L1OutPred
P3L1OutPred
...


### 15.2 Patient IDs must match folder names

The `PatientID` values in Excel must exactly match patient subfolder names.

Example:


Excel PatientID: P1
Folder name:     P1


### 15.3 Model config should contain output bounds

The trained model file should ideally contain `config` with:


PDmax
T1max
T2max
g1max
g2max
g3max


Otherwise, the sigmoid scaling step may not work correctly.



## 16. Software requirements

The script requires:


MATLAB
Deep Learning Toolbox
Image Processing Toolbox
NIfTI read/write support
GPU support recommended


Optional:


Signal Processing Toolbox


The code tries to use `gausswin` for the Gaussian blending window. If `gausswin` is unavailable, it uses a manual Gaussian fallback.