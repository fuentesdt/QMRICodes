function dicomLoaderAndViewer
% DICOM Slice Viewer with Slider
% Save as: dicomLoaderAndViewer.m
% Run with: dicomLoaderAndViewer

clc; close all;

%% 1) Select folder
dicomFolder = uigetdir(pwd, 'Select folder with DICOM files');
if dicomFolder == 0
    error('No folder selected.');
end

%% 2) Read and sort DICOM files
files = dir(fullfile(dicomFolder, '*.dcm'));
if isempty(files)
    error('No DICOM (.dcm) files found in the selected folder.');
end

numFiles = numel(files);
instanceNums = nan(numFiles,1);

for i = 1:numFiles
    info = dicominfo(fullfile(dicomFolder, files(i).name));
    if isfield(info, 'InstanceNumber')
        instanceNums(i) = double(info.InstanceNumber);
    else
        instanceNums(i) = i;
    end
end

[~, sortIdx] = sort(instanceNums);
files = files(sortIdx);

%% 3) Load into volume
sampleImg = dicomread(fullfile(dicomFolder, files(1).name));

if ndims(sampleImg) == 2
    % Grayscale stack
    vol = zeros([size(sampleImg), numFiles], 'like', sampleImg);
    for i = 1:numFiles
        vol(:,:,i) = dicomread(fullfile(dicomFolder, files(i).name));
    end
    isRGB = false;
else
    % Color or multi-channel
    vol = zeros([size(sampleImg), numFiles], 'like', sampleImg);
    for i = 1:numFiles
        vol(:,:,:,i) = dicomread(fullfile(dicomFolder, files(i).name));
    end
    isRGB = true;
end

numSlices = size(vol, ndims(vol));

%% 4) Create figure + UI
hFig = figure('Name','DICOM Slice Viewer', ...
              'NumberTitle','off', ...
              'Color','w', ...
              'Units','normalized', ...
              'Position',[0.2 0.1 0.6 0.8]);

hAx = axes('Parent', hFig, ...
           'Position',[0.05 0.12 0.9 0.83]);

if ~isRGB
    colormap(hAx, gray);
end

% Initial slice
currentSlice = 1;
if ~isRGB
    hImg = imagesc(vol(:,:,currentSlice), 'Parent', hAx);
else
    hImg = image(vol(:,:,:,currentSlice), 'Parent', hAx);
end
axis(hAx, 'image', 'off');
title(hAx, sprintf('Slice %d / %d', currentSlice, numSlices), 'FontSize', 14);

% Slider
hSlider = uicontrol('Parent', hFig, ...
    'Style','slider', ...
    'Units','normalized', ...
    'Position',[0.15 0.03 0.7 0.04], ...
    'Min',1, 'Max',numSlices, ...
    'Value',currentSlice, ...
    'SliderStep',[1/max(1,numSlices-1), min(1,10/max(1,numSlices-1))], ...
    'Callback', @onSliderMove);

% Text label
hText = uicontrol('Parent', hFig, ...
    'Style','text', ...
    'Units','normalized', ...
    'Position',[0.02 0.03 0.12 0.04], ...
    'BackgroundColor','w', ...
    'String',sprintf('Slice: %d / %d', currentSlice, numSlices), ...
    'HorizontalAlignment','left');

%% ===== Nested callback (has access to vol, numSlices, etc.) =====
    function onSliderMove(src, ~)
        k = round(get(src, 'Value'));
        k = max(1, min(numSlices, k));

        if ~isRGB
            set(hImg, 'CData', vol(:,:,k));
        else
            set(hImg, 'CData', vol(:,:,:,k));
        end

        title(hAx, sprintf('Slice %d / %d', k, numSlices), 'FontSize', 14);
        set(hText, 'String', sprintf('Slice: %d / %d', k, numSlices));
    end

end
