function [data] = SEV2mat(SEV_DIR, varargin)
%SEV2MAT  TDT SEV file format extraction.
%   data = SEV2mat(SEV_DIR), where SEV_DIR is a string, retrieves
%   all sev data from specified directory in struct format. SEV files
%   are generated by an RS4 Data Streamer, or by enabling the Discrete
%   Files option in the Synapse Stream Data Storage gizmo, or by setting
%   the Unique Channel Files option in Stream_Store_MC or Stream_Store_MC2
%   macro to Yes in OpenEx.
%
%   data    contains all continuous data (sampling rate and raw data)
%
%   data = SEV2mat(SEV_DIR,'parameter',value,...)
%
%   'parameter', value pairs
%      'T1'         scalar, retrieve data starting at T1 (default = 0 for
%                       beginning of recording)
%      'T2'         scalar, retrieve data ending at T2 (default = 0 for end
%                       of recording)
%      'CHANNEL'    integer, returns the sev data from specified channel
%                       only (default = 0 for all channels)
%      'RANGES'     array of valid time range column vectors
%      'JUSTNAMES'  boolean, retrieve only the valid event names
%      'EVENTNAME'  string, specific event name to retrieve data from
%      'VERBOSE'    boolean, set to false to disable console output
%      'DEVICE'     string, connect to specific RS4 device.  DEVICE can be
%                       the IP address or NetBIOS name of RS4-device
%                       (e.g. RS4-41001).  Requires TANK and BLOCK
%                       parameters
%      'TANK'       string, tank on RS4 to retrieve data from. Requires
%                       DEVICE and BLOCK parameters
%      'BLOCK'      string, block on RS4 to retrieve data from. Requires
%                       DEVICE and TANK parameters
%      'FS'         float, sampling rate override. Useful for lower
%                       sampling rates that aren't correctly written into
%                       the SEV header.
%

if ~mod(nargin, 2)
    error('not enough input arguments')
end

% defaults
CHANNEL   = 0;
EVENTNAME = '';
DEVICE    = '';
TANK      = '';
BLOCK     = '';
T1        = 0;
T2        = 0;
FS        = 0;
RANGES    = [];
VERBOSE   = 0;
JUSTNAMES = 0;

VALID_PARS = {'CHANNEL','EVENTNAME','DEVICE','TANK','BLOCK','T1','T2' ...
    'RANGES','VERBOSE','JUSTNAMES','FS'};

% parse varargin
for ii = 1:2:length(varargin)
    if ~ismember(upper(varargin{ii}), VALID_PARS)
        error('%s is not a valid parameter. See help SEV2mat.', upper(varargin{ii}));
    end
    eval([upper(varargin{ii}) '=varargin{ii+1};']);
end

if any([~isempty(DEVICE) ~isempty(TANK) ~isempty(BLOCK)])
    if any([isempty(DEVICE) isempty(TANK) isempty(BLOCK)])
        error('DEVICE, TANK and BLOCK must all be specified');
    else
        SEV_DIR = sprintf('\\\\%s\\data\\%s\\%s\\', DEVICE, TANK, BLOCK);
    end
end

data = [];

ALLOWED_FORMATS = {'single','int32','int16','int8','double','int64'};

xxx = exist(SEV_DIR, 'file');
if xxx == 2
    % treat as single file only
    file_list = [dir(SEV_DIR)];
    SEV_DIR = [fileparts(SEV_DIR) filesep];
elseif xxx == 7
    % treat as directory 
    if strcmp(SEV_DIR(end), filesep) == 0
        SEV_DIR = [SEV_DIR filesep];
    end
    file_list = dir([SEV_DIR '*.sev']);
end

nfiles = length(file_list);
if nfiles < 1
    warning(['no sev files found in ' SEV_DIR])
    return
end

if FS > 0
    warning('Assuming %s SEV sampling rate is %.4f Hz', EVENTNAME, FS)
end
    
% find out what data we think is here
for i = 1:length(file_list)
    [pathstr, name, ext] = fileparts(file_list(i).name);
    
    % find channel number
    matches = regexp(name, '_[Cc]h[0-9]*', 'match');
    if ~isempty(matches)
        sss = matches{end};
        file_list(i).chan = str2double(sss(4:end));
    end
    
    % find starting hour
    matches = regexp(name, '-[0-9]*h', 'match');
    if ~isempty(matches)
        sss = matches{end};
        file_list(i).hour = str2double(sss(2:end-1));
    else
        file_list(i).hour = 0;
    end
    
    % check file size
    file_list(i).data_size = file_list(i).bytes - 40;
    
    path = [SEV_DIR file_list(i).name];
    fid = fopen(path, 'rb');
    if fid < 0
        warning([path ' not opened'])
        return
    end
    
    % create and fill streamHeader struct
    streamHeader = [];
    
    streamHeader.fileSizeBytes   = fread(fid,1,'uint64');
    streamHeader.fileType        = char(fread(fid,3,'char')');
    streamHeader.fileVersion     = fread(fid,1,'char');
    
    % event name of stream
    s = regexp(name, '_', 'split');
    if length(s) > 1
        streamHeader.eventName = s{end-1};
    else
        streamHeader.eventName = name;
    end
    
    if streamHeader.fileVersion < 4
        
        % prior to v3, OpenEx and RS4 were not setting this properly 
        % (one of them was flipping it)
        if streamHeader.fileVersion == 3
            streamHeader.eventName  = char(fread(fid,4,'char')');
        else
            oldEventName  = char(fread(fid,4,'char')');
            %streamHeader.eventName  = fliplr(char(fread(fid,4,'char')'));
        end
        %else
        %    streamHeader.eventName  = fliplr(char(fread(fid,4,'char')'));
        %end
        
        % current channel of stream
        streamHeader.channelNum        = fread(fid, 1, 'uint16');
        file_list(i).chan = streamHeader.channelNum;
        % total number of channels in the stream
        streamHeader.totalNumChannels  = fread(fid, 1, 'uint16');
        % number of bytes per sample
        streamHeader.sampleWidthBytes  = fread(fid, 1, 'uint16');
        reserved                 = fread(fid, 1, 'uint16');
        
        % data format of stream in lower four bits
        streamHeader.dForm      = ALLOWED_FORMATS{bitand(fread(fid, 1, 'uint8'),7)+1};
        
        % used to compute actual sampling rate
        streamHeader.decimate   = fread(fid, 1, 'uint8');
        streamHeader.rate       = fread(fid, 1, 'uint16');
    else
        error(['unknown version ' num2str(streamHeader.fileVersion)]);
    end
    
    % compute sampling rate
    if streamHeader.fileVersion > 0
        %streamHeader.fs = 2^(streamHeader.rate)*25000000/2^12/streamHeader.decimate;
        streamHeader.fs = 2^(streamHeader.rate - 12) * 25000000 / streamHeader.decimate;

    else
        % make some assumptions if we don't have a real header
        streamHeader.dForm = 'single';
        streamHeader.fs = 24414.0625;
        s = regexp(file_list(i).name, '_', 'split');
        streamHeader.eventName = s{end-1};
        streamHeader.channelNum = str2double(regexp(s{end},  '\d+', 'match'));
        file_list(i).chan = streamHeader.channelNum;
        warning('%s has empty header; assuming %s ch %d format %s\nupgrade to OpenEx v2.18 or above\n', ...
            file_list(i).name, streamHeader.eventName, ...
            streamHeader.channelNum, streamHeader.dForm);
    end
    
    if FS > 0
        streamHeader.fs = FS;
    end
    
    % check variable name
    %varname = matlab.lang.makeValidName(streamHeader.eventName);
    varname = streamHeader.eventName;
    for ii = 1:numel(varname)
        if ii == 1
            if ~isnan(str2double(varname(ii)))
                varname(ii) = 'x';
            end
        end
        if ~isletter(varname(ii)) && isnan(str2double(varname(ii)))
            varname(ii) = '_';
        end
    end
    
    if ~isvarname(streamHeader.eventName)
        warning('%s is not a valid Matlab variable name, changing to %s', streamHeader.eventName, varname);
    end
    
    func = str2func(streamHeader.dForm);
    tempvar = func(zeros(1,1));
    w = whos('tempvar');
    file_list(i).npts = file_list(i).data_size / w.bytes;
    file_list(i).fs = streamHeader.fs;
    file_list(i).dForm = streamHeader.dForm;
    file_list(i).eventName = streamHeader.eventName;
    file_list(i).varName = varname;
    fclose(fid);
end

eventNames = unique({file_list.eventName});
if JUSTNAMES
    data = eventNames;
    return
end

if T2 > 0
    validTimeRange = [T1; T2];
else
    validTimeRange = [T1; Inf];
end

if ~isempty(RANGES)
    validTimeRange = RANGES;
end
numRanges = size(validTimeRange, 2);
if numRanges > 0
    data.time_ranges = RANGES;
end

for ev = 1:numel(eventNames)
    
    thisEvent = eventNames{ev};
    
    if ~strcmp(EVENTNAME, '') && ~strcmp(EVENTNAME, thisEvent)
        continue
    end
    
    file_list_temp = [];
    for j = 1:length(file_list)
        if strcmp(file_list(j).eventName, thisEvent)
            file_list_temp = [file_list_temp file_list(j)];
        end
    end
    
    fs = file_list_temp(1).fs;
    eventName = file_list_temp(1).eventName;
    dForm = file_list_temp(1).dForm;
    
    max_chan = max([file_list_temp.chan]);
    min_chan = min([file_list_temp.chan]);
    max_hour = max([file_list_temp.hour]);
    hour_values = sort(unique([file_list_temp.hour]));
    
    % preallocate data array
    if CHANNEL > 0
        matching_ch = find([file_list_temp.chan] == CHANNEL);
    else
        matching_ch = find([file_list_temp.chan] == min_chan);
    end
    
    if CHANNEL > 0 && isempty(matching_ch)
        warning('Channel %d not found in %s store', CHANNEL, eventName);
        continue
    end
    
    % determine total samples if there is chunking
    total_samples = 0;
    for jjj = hour_values
        temp_num = intersect(find([file_list_temp.hour] == jjj), matching_ch);
        total_samples = total_samples + max([file_list_temp(temp_num).npts]);
    end
    
    % if we are doing time filtering, determine which files we need to read
    % from and how many samples
    minSample = zeros(1, numRanges);
    maxSample = zeros(1, numRanges);
    minSampleOffset = zeros(1, numRanges);
    maxSampleOffset = zeros(1, numRanges);
    minHourOffset = zeros(1, numRanges);
    maxHourOffset = zeros(1, numRanges);
    for jj = 1:numRanges
        minSample(jj) = max(ceil(validTimeRange(1,jj) * fs), 0) + 1;
        maxSample(jj) = min(max(floor(validTimeRange(2,jj) * fs), 0) + 1, total_samples);
        minHourOffset(jj) = floor((minSample(jj)-1) / max([file_list_temp(temp_num).npts]));
        maxHourOffset(jj) = floor((maxSample(jj)-1) / max([file_list_temp(temp_num).npts]));
        minSampleOffset(jj) = mod(minSample(jj)-1, total_samples) + 1;
        maxSampleOffset(jj) = mod(maxSample(jj)-1, total_samples) + 1;
    end
    
    % now allocate it
    if CHANNEL > 0
        channels = CHANNEL;
    else
        channels = sort(unique([file_list_temp.chan]));
    end
    data.(file_list_temp(1).varName).data = cell(1, numRanges);
    for jj = 1:numRanges
        data.(file_list_temp(1).varName).data{jj} = zeros(numel(channels), maxSample(jj) - minSample(jj) + 1, dForm);
    end
    data.(file_list_temp(1).varName).channels = channels;
    loop = channels;
    
    % loop through the time ranges
    for ii = 1:numRanges
        
        % loop through the channels
        ind = 1;
        for jj = loop
            chanIndex = 1;
            matching_ch = find([file_list_temp.chan] == jj);
        
            % loop through the chunks
            for kk = minHourOffset(ii):maxHourOffset(ii)
            
                file_num = intersect(find([file_list_temp.hour] == kk), matching_ch);
                
                % open file
                path = [SEV_DIR file_list_temp(file_num).name];
                fid = fopen(path, 'rb');
                if fid < 0
                    warning([path ' not opened'])
                    return
                end
            
                % skip first 40 bytes
                fread(fid, 10, 'single');
                
                % read rest of file into data array as correct format
                varname = file_list_temp(file_num).varName;
                data.(varname).name = eventName;
                data.(varname).fs = fs;
                
                if kk == minHourOffset(ii)
                    firstSample = minSampleOffset(ii)-1;
                else
                    firstSample = 0;
                end
                if kk == maxHourOffset(ii)
                    lastSample = maxSampleOffset(ii);
                else
                    lastSample = Inf;
                end
                
                % skip ahead
                fread(fid, firstSample, dForm);
                readSize = lastSample - firstSample;
                
                data.(varname).data{ii}(ind, chanIndex:chanIndex + readSize - 1) = fread(fid, readSize, ['*' dForm])';
                chanIndex = chanIndex + readSize;
                
                % close file
                fclose(fid);
                
                if VERBOSE
                    file_list(file_num)
                end
                ind = ind + 1;
            end
            data.(varname).data{ii} = data.(varname).data{ii}(:,1:chanIndex-1);
        end
    end
    if numRanges == 1
        data.(varname).data = [data.(varname).data{ii}];
    end
end