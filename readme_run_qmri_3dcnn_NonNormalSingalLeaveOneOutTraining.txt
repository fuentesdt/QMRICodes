README — Leave-One-Patient-Out qMRI 3D CNN Training

This MATLAB script trains a 3D U-Net for quantitative MRI/qMRI mapping
using a leave-one-patient-out training strategy. The goal is to train
separate models where, in each training run, one patient is excluded
from the training data. The network takes three structural MRI contrasts
as input — T1-weighted, T2-weighted, and FLAIR — and predicts six 3D
output maps: PD, T1, T2, g1, g2, and g3. The training uses both
reference-map supervision and MRI signal-physics consistency.

What the code does

The script:

1.  Loops over all patients from 1 to Num_patients.
2.  For each loop, leaves one patient out from training.
3.  Reads a fold-specific Excel file containing acquisition parameters
    for all training patients except the left-out patient.
4.  Finds patient folders inside the current working directory.
5.  Loads each training patient’s MRI volumes and reference qMRI maps.
6.  Extracts overlapping 3D patches of size 64 × 64 × 64.
7.  Builds a 3D U-Net with 3 input channels and 6 output channels.
8.  Trains the network to predict:
    -   PD map
    -   T1 map
    -   T2 map
    -   gain map for T1w signal, g1
    -   gain map for T2w signal, g2
    -   gain map for FLAIR signal, g3
9.  Saves fold-specific trained model checkpoints and training-loss
    plots.

Leave-one-patient-out logic

The main loop is:

    Num_patients = 11;

    for L = 1:Num_patients

For each value of L, the code trains one model.

For example:

    L = 1 → Patient 1 is left out from training
    L = 2 → Patient 2 is left out from training
    L = 3 → Patient 3 is left out from training
    ...
    L = 11 → Patient 11 is left out from training

The code itself does not directly remove the patient from the data.
Instead, the fold-specific Excel file controls which patients are
included.

For example:

    acq_paramsP1.xlsx

should contain all patients except Patient 1.

Similarly:

    acq_paramsP2.xlsx

should contain all patients except Patient 2.

Required folder structure

The code assumes that the current MATLAB folder is the project root:

    config.rootDir = pwd;

So the base folder should look like this:

    ProjectRoot/
    │
    ├── run_qmri_3dcnn_Leave_One_Out.m
    │
    ├── acq_paramsP1.xlsx
    ├── acq_paramsP2.xlsx
    ├── acq_paramsP3.xlsx
    ├── ...
    ├── acq_paramsP11.xlsx
    │
    ├── Patient1/
    │   ├── PREOP_T1_W_S.nii.gz
    │   ├── PREOP_AxT2_W_S.nii.gz
    │   ├── PREOP_FLAIR_W_S.nii.gz
    │   ├── pdmap.nii.gz
    │   ├── t1map.nii.gz
    │   ├── t2map.nii.gz
    │   └── mask.nii.gz
    │
    ├── Patient2/
    │   ├── PREOP_T1_W_S.nii.gz
    │   ├── PREOP_AxT2_W_S.nii.gz
    │   ├── PREOP_FLAIR_W_S.nii.gz
    │   ├── pdmap.nii.gz
    │   ├── t1map.nii.gz
    │   ├── t2map.nii.gz
    │   └── mask.nii.gz
    │
    └── trained_models_P1/
    └── trained_models_P2/
    └── trained_models_P3/
    ...
    └── trained_models_P11/

The output folders are automatically created.

Required Excel files

The code requires one Excel file per leave-one-out fold:

    acq_paramsP1.xlsx
    acq_paramsP2.xlsx
    acq_paramsP3.xlsx
    ...
    acq_paramsP11.xlsx

Each Excel file must contain the acquisition parameters for the patients
used in that fold.

Each file must contain this patient ID column:

    PatientID

and these acquisition-parameter columns:

    TRT1
    TET1
    FAT1_deg
    TRT2
    TET2
    TRFLAIR
    TEFLAIR
    TIFLAIR

Each row corresponds to one patient. The PatientID value must exactly
match the patient subfolder name.

Required files inside each patient folder

Each valid patient folder must contain all of these files:

    PREOP_T1_W_S.nii.gz
    PREOP_AxT2_W_S.nii.gz
    PREOP_FLAIR_W_S.nii.gz
    pdmap.nii.gz
    t1map.nii.gz
    t2map.nii.gz
    mask.nii.gz

If any file is missing, that patient is skipped.

Inputs to the network

The network input is a 3-channel 3D patch:

    Channel 1: T1-weighted MRI
    Channel 2: T2-weighted MRI
    Channel 3: FLAIR MRI

Each patch has size:

    64 × 64 × 64 × 3

The code also attaches 8 acquisition parameters to each patch:

    TRT1, TET1, FAT1, TRT2, TET2, TRFLAIR, TEFLAIR, TIFLAIR

The flip angle is converted from degrees to radians before training.

Outputs from the network

The network predicts 6 channels:

    Channel 1: PD
    Channel 2: T1
    Channel 3: T2
    Channel 4: g1
    Channel 5: g2
    Channel 6: g3

The outputs are constrained using sigmoid scaling:

    PD: 0 to 150
    T1: 0 to 5000 ms
    T2: 0 to 3000 ms
    g1: 0 to 500
    g2: 0 to 500
    g3: 0 to 500

Output files saved by the code

For each fold, the trained models and figures are saved in a separate
folder:

    trained_models_P1/
    trained_models_P2/
    trained_models_P3/
    ...
    trained_models_P11/

For example, when L = 1, the output folder is:

    trained_models_P1/

The script saves:

    best_epoch.mat
    epoch020.mat
    epoch040.mat
    epoch060.mat
    ...
    LossesFigure.png
    LossesFigure.fig

best_epoch.mat contains the best network for that fold based on
validation loss. Periodic checkpoints are saved every 20 epochs.

Training strategy

The code uses:

    Patch size: 64 × 64 × 64
    Patch stride: 32 × 32 × 32
    Batch size: 2
    Epochs: 200
    Learning rate: 2e-4
    Optimizer: AdamW
    Weight decay: 1e-4
    Train/validation split: 80/20 patch-level random split

Only patches with at least 20% brain-mask coverage are used.

Network architecture

The code builds a 3D U-Net using:

    buildUNet3D(config.patchSize, 3, config.baseFilters, 6)

This means:

    Input channels: 3
    Output channels: 6
    Base filters: 32
    Patch size: 64 × 64 × 64

The architecture contains:

    Encoder path
    Bottleneck
    Decoder path
    Skip connections
    Final 1 × 1 × 1 convolution layer

Loss function

The active loss is:

    Total loss = signal loss + parameter loss

The parameter loss compares predicted maps against reference maps:

    PD prediction vs pdmap.nii.gz
    T1 prediction vs t1map.nii.gz
    T2 prediction vs t2map.nii.gz

The signal loss synthesizes T1w, T2w, and FLAIR signals from predicted
PD, T1, T2, g1, g2, and g3 using MRI signal equations, then compares
them with the measured input images.

Important notes

The code uses:

    gpuDevice(3)

This means it tries to use the third GPU. If the computer has fewer
GPUs, modify this accordingly.

What files are needed to run without errors

To run the complete leave-one-patient-out training without errors, you
need:

    1. The MATLAB script file
    2. Patient folders for all patients
    3. NIfTI files inside each patient folder
    4. One fold-specific Excel file per leave-one-out run
    5. MATLAB Deep Learning Toolbox
    6. MATLAB support for reading NIfTI files
    7. Sufficient CPU/GPU memory for 3D patch training
