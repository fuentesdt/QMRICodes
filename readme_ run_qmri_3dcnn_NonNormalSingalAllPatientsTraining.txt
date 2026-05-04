

This MATLAB script trains a 3D U-Net for quantitative MRI/qMRI mapping.
Its goal is to learn a model that takes three structural MRI contrasts
as input — T1-weighted, T2-weighted, and FLAIR — and predicts six 3D
output maps: PD, T1, T2, g1, g2, and g3. The network is trained using
both direct reference-map supervision and MRI signal-physics
consistency.

What the code does

The script:

1.  Reads patient acquisition parameters from an Excel file (acq_params.xlsx).
2.  Finds patient folders inside the current working directory.
3.  Loads each patient’s MRI volumes and reference qMRI maps.
4.  Extracts overlapping 3D patches of size 64 × 64 × 64.
5.  Builds a 3D U-Net with 3 input channels and 6 output channels.
6.  Trains the network to predict:
    -   PD map
    -   T1 map
    -   T2 map
    -   gain map for T1w signal, g1
    -   gain map for T2w signal, g2
    -   gain map for FLAIR signal, g3
7.  Saves the trained model checkpoints and training-loss plots.

Required folder structure

The code assumes that the current MATLAB folder is the project root:

    config.rootDir = pwd;

So your base folder should look like this:

    ProjectRoot/
    │
    ├── acq_params.xlsx
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
    └── trained_models_All/

The output folder is automatically created:

    trained_models_All

Required Excel file

The script requires this file in the root folder:

    acq_params.xlsx

It must contain a patient ID column:

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

The trained models and figures are saved in:

    trained_models_All/

The script saves:

    best_epoch.mat
    epoch020.mat
    epoch040.mat
    ...
    LossesFigure.png
    LossesFigure.fig

best_epoch.mat contains the best network based on validation loss.
Periodic checkpoints are saved every 20 epochs.

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

Loss function

The active loss is:

    Total loss = signal loss + parameter loss

The parameter loss compares predicted maps against reference maps:

    PD prediction vs pdmap.nii.gz
    T1 prediction vs t1map.nii.gz
    T2 prediction vs t2map.nii.gz

The signal loss synthesizes T1w, T2w, and FLAIR signals from the
predicted PD, T1, T2, g1, g2, and g3 maps using MRI signal equations,
then compares them with the measured input images.

Regularization terms such as TV loss and gain smoothness are present in
the code but currently commented out.

Important note

Although there is a function called normalizeContrasts, the current main
script does not actually call it. Therefore, the input T1w, T2w, and
FLAIR images are used directly as read from the NIfTI files.
