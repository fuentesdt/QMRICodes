
The new full dataset is stored in a csv dataframe with this schema for the columns.
AnonymizationID,MRN,Study UID,Series UID (Ax MAGiC),dicom_path,synthentic_path,T1W Synthetic,T2W Synthetic,FLAIR Synthetic,PS Synthetic,match_status,n_matches_for_MRN,n_matches_for_StudyUID,n_matches_for_MRN_StudyUID


update the scripts in the 

--------------------------------------------------
RECOMMENDED WORKFLOW
--------------------------------------------------

1. Train using:
   run_qmri_3dcnn_NonNormalSingalLeaveOneOutTraining_Automatic.m

2. Predict using:
   predict_qmri_3dcnn_NonNormalSignal_AutomatedAnonymizedFolders.m

to run a 5 fold CV for the train and predict steps on this new. follow the same workflow as ../radpathsandbox/CLAUDE.md to protect PHI
