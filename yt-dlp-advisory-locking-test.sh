#!/bin/bash

# This simulates a user launching yt-dlp to download playlist A, and then later deciding to launch a
# second yt-dlp process to download a _different_ playlist B. The problem is, playlist A and B both
# contain ID Gwo3pEH7hUE.
#
# This duplicate ID causes a race condition (depending on the specifics of the playlist length and
# download options), where one process can encounter Gwo3pEH7hUE while the other process already
# has an advisory lock on either the video or audio track.
#
# The race shouldnt matter, because the process without a lock should not write to the file, but it does, because:
#       utils.py:
#           self.f = io.open(filename, mode, encoding=encoding)
#       results in:
#           strace:
#               openat(AT_FDCWD</delme/_yt_dlp_delme/_yt_dlp_test_1646631804>, "youtube__Gwo3pEH7hUE.f160.mp4.part", O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0666) = 4</delme/_yt_dlp_delme/_yt_dlp_test_1646631804/youtube__Gwo3pEH7hUE.f160.mp4.part>
#       which truncates the file, even though this process does not have an advisory lock,
#
#

# The below test is using --match-filter and --size to make the race condition trigger reliabely.

echo -e "\n\nSTARTING $0" "$@"

set -o pipefail
set -o nounset
yt_dlp_HEAD_repo="/home/user/_myapps/yt-dlp"  # this repo's HEAD should reflect the version of yt-dlp this script exectutes
test -d "${yt_dlp_HEAD_repo}/.git/" || { echo "plese set yt_dlp_HEAD_repo on line 43 of $(readlink -f "$0")" ; exit 1 ; }
cd "${yt_dlp_HEAD_repo}" || exit 1
git_HEAD_commit=$(git rev-parse --short HEAD)
set +o nounset
set +o pipefail


log(){
    echo -e "$*" > /dev/stderr
}

boolish(){
    test "${1}" -eq 0 && echo "PASS" && exit 0
    test "${1}" -eq 1 && echo "fail" && exit 0
}

ffmpeg_test_file(){
    #file=$(readlink -f "${1}")  # too verbose
    file="${1}"
    log "\nffmpeg_test_file(): ${file}"
    #pwd
    test -e "${file}" || { log "\nCODE_ERROR: file: ${file} does not exist\n" ; exit 1 ; }
    ffmpeg -v error -xerror -i "${file}" -f null - 2>&1
    ffmpeg_exit_code_test_1="$?"
    log "ffmpeg_exit_code_test_1: ${ffmpeg_exit_code_test_1}"
    # this exits > 0 IFF ffmpeg encountered an error (by detecting any bytes it writes to stdout)
    if read -d '' -rn1 < <(set -m ; exec unbuffer ffmpeg -threads 2 -v error -i "${file}" -f null /dev/stdout); then printf 'ffmpeg: %s detected an error\n' "$!"; kill -TERM $!; fi; wait "$!"
    ffmpeg_exit_code_test_2="$?"
    if [ "${ffmpeg_exit_code_test_1}" -gt 0 ] && [ "${ffmpeg_exit_code_test_2}" -gt 0 ];
    then
        log "\nERROR: both ffmpeg test methods agree: ${file} is corrupt:\n"
        log "ftrace log for ${file}:"
        grep ${file} fatrace.log || exit 1
        log
        return "${ffmpeg_exit_code_test_1}"
    elif [ "${ffmpeg_exit_code_test_1}" -eq 0 ] && [ "${ffmpeg_exit_code_test_2}" -eq 0 ];
    then
        log "both ffmpeg test methods agree: ${1} is good"
        return "${ffmpeg_exit_code_test_2}"
    else
        log "\nCODE_ERROR: ffmpeg tests disagree"
        exit 1
    fi
}


whereis fatrace > /dev/null || { log "fatrace not found, it's used to capture the file operations, please install" ; exit 1; }
whereis ffmpeg > /dev/null || { log "ffmpeg not found, is used to detect corrupt files, please install" ; exit 1; }
whereis stdbuf > /dev/null || { log "stdbuf not found, is used to make correctly ordered log files, please install" ; exit 1; }
whereis strace > /dev/null || { log "strace not found, is used to log system calls, please install" ; exit 1; }
sudo /bin/true  # prompt user for sudo pw so the fatrace line below executes immediately


# make stdout unbuffered so logging looks nice
if [[ "$1" != __UNBUFFERED__ ]]; then
    #set -x
    stdbuf -oL "$0" __UNBUFFERED__
    #set +x
else
    shift #discard __UNBUFFERED__
    set -o nounset
    temp_dir="_yt_dlp_test_$(date +%s)"
    mkdir "${temp_dir}" || exit 1
    cd "${temp_dir}" || exit 1

    # capture this terminal session to logfile
    exec > >(tee -i terminal_log.txt)
    exec 2>&1
    #log "Using temp_dir: ${temp_dir}"

    cp -v "$0" .  # add a copy of this script to the log folder

    sudo fatrace --current-mount --timestamp --timestamp --output fatrace.log &
    sudo_pid="$!"
    sleep 2  # make sure fatrace is active
    fatrace_pid=$(ps --ppid "${sudo_pid}" -o pid=)
    #log "fatrace_pid: ${fatrace_pid}"

    set -x
    # process_A (playlist has 70 videos) (the filter pairs it down to 3, one being Gwo3pEH7hUE)
    unbuffer strace -ff -y -s 128 --output yt-dlp.strace.log --timestamps=format:unix,precision:ns \
    /usr/bin/yt-dlp "https://www.youtube.com/playlist?list=PLaWNxqesaSyhjP0duSOH8C_MJROI1tmD6" \
        --match-filter "id~='\b[A-Z].*[A-Z]E\b'" \
        -S +size \
        --output "%(extractor)s__%(id)s.%(ext)s" \
        --keep-video \
        --no-color --verbose > process_A.yt_dlp.log 2>&1 &
    set +x
    process_A_pid="$!"
    log "process_A ${process_A_pid} started"
    ps -f -auxww | grep "${process_A_pid}"

    set -x
    # process_B (playlist has 34 videos) (the filter pairs the list down to 1, Gwo3pEH7hUE)
    unbuffer strace -ff -y -s 128 --output yt-dlp.strace.log --timestamps=format:unix,precision:ns \
    /usr/bin/yt-dlp "https://www.youtube.com/playlist?list=PLmlhzhpHN7Z2e5DPni8bWuNr9_OVR2nCX" \
        --match-filter "id~='\b[A-Z].*[A-Z]E\b'" \
        -S +size \
        --output "%(extractor)s__%(id)s.%(ext)s" \
        --keep-video \
        --no-color --verbose > process_B.yt_dlp.log 2>&1 &
    set +x
    process_B_pid="$!"
    log "process_B ${process_B_pid} started"
    ps -f -auxww | grep "${process_A_pid}"

    log "waiting for processes: ${process_A_pid} ${process_B_pid} to exit"

    wait "${process_A_pid}" ; log "process_A exited $?"
    wait "${process_B_pid}" ; log "process_B exited $?"

    sudo kill "${fatrace_pid}" || exit 1
    cat fatrace.log | grep -v strace > fatrace.log.no_strace.log || exit 1
    mv -f fatrace.log.no_strace.log fatrace.log || exit 1

    sed -i "s/^/[${process_A_pid}] /" process_A.yt_dlp.log || exit 1
    sed -i "s/^/[${process_B_pid}] /" process_B.yt_dlp.log || exit 1

    # make strace-log-merge include the fatrace log
    cp -i fatrace.log yt-dlp.strace.log."${fatrace_pid}" || exit 1

    strace-log-merge yt-dlp.strace.log > yt-dlp.strace.log || exit 1
    test -s yt-dlp.strace.log && rm -f yt-dlp.strace.log.* || exit 1

    # yt-dlp.strace.log=yt-dlp.strace.log.${}
    #grep -v "^brk(" yt-dlp.strace.log > yt-dlp.strace.log.io.log || exit 1
    #grep -v "^brk(" yt-dlp.strace.log > yt-dlp.strace.log.io.log || exit 1

    log "INFO: unlinking unrelated ID's, any failures here are unexpected"
    set -x
    rm -f youtube__Q6NBnPfPhWE.f139.m4a || exit 1
    rm -f youtube__Q6NBnPfPhWE.f160.mp4 || exit 1
    rm -f youtube__Q6NBnPfPhWE.mp4      || exit 1
    rm -f youtube__V1aONINVkSE.f139.m4a || exit 1
    rm -f youtube__V1aONINVkSE.f160.mp4 || exit 1
    rm -f youtube__V1aONINVkSE.mp4      || exit 1
    set +x

    expected_output_file_count=3

    output_file_count="$(find . -type f -name "youtube__Gwo3pEH7hUE*" | wc -l)"
    if [ "${output_file_count}" -ne "${expected_output_file_count}" ];
    then
        log "\nERROR: (${expected_output_file_count}) youtube__* output files were expected, but (${output_file_count}) were found:\n"
    fi

    /bin/ls -alh || exit 1

    if [ -s youtube__Gwo3pEH7hUE.f160.mp4 ] && [ -s youtube__Gwo3pEH7hUE.f139.m4a ] && [ ! -e youtube__Gwo3pEH7hUE.mp4 ];
    then
        log "\nERROR: both youtube__Gwo3pEH7hUE.f160.mp4 and youtube__Gwo3pEH7hUE.f139.m4a exist, but youtube__Gwo3pEH7hUE.mp4 does not, regardless, the manual merge attempt below will attempt to check if either input file is corrupt\n"
    fi

    set -x
    ffmpeg -y -loglevel warning -xerror -i file:youtube__Gwo3pEH7hUE.f160.mp4 -i file:youtube__Gwo3pEH7hUE.f139.m4a -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart file:youtube__Gwo3pEH7hUE.manual.mp4
    ffmpeg_manual_merge_exit_code="$?"
    set +x
    #log "ffmpeg_manual_merge_exit_code: ${ffmpeg_manual_merge_exit_code}"
    if [ "${ffmpeg_manual_merge_exit_code}" -gt 0 ];
    then
        log "\nERROR: ffmpeg manual merge job exited nonzero, either one or both of the input files is corrupt"
        if [ "${output_file_count}" -eq ${expected_output_file_count} ];
        then
            #echo "NotImplementedError(automerge worked but manual merge failed?)" ; exit 1
            echo "ERROR: the automerge worked, but the manual merge failed. Need a logging filesystem to understand what happened without parsing strace logs, but most likely, one of the input files changed after the automerge read them."
            test -s youtube__Gwo3pEH7hUE.mp4 || { echo "IMPLEMENTATION_ERROR: youtube__Gwo3pEH7hUE.mp4 exists" ; exit 1 ; }
            test ! -x youtube__Gwo3pEH7hUE.manual.mp4 || { echo "IMPLEMENTATION_ERROR: youtube__Gwo3pEH7hUE.manual.mp4 does not exist" ; exit 1 ; }
        fi
    else
        log "\nINFO: ffmpeg manual merge job exited 0, it appears that there is no file corruption.\n"
        if [ "${output_file_count}" -eq 2 ];
        then
            log "ERROR... but neither process_A or process_B tried to merge, so this is the 'nobody merged, no corruption' case.\n"
        fi
    fi

    log "\nINFO: checking each Gwo3pEH7hUE input file:"
    log "\nls -alh youtube__Gwo3pEH7hUE*"
    ls -alh youtube__Gwo3pEH7hUE* || exit 1
    ffmpeg_test_file youtube__Gwo3pEH7hUE.f160.mp4
    video_test_exit_code=$?
    log "video_test_exit_code: ${video_test_exit_code}"
    ffmpeg_test_file youtube__Gwo3pEH7hUE.f139.m4a
    audio_test_exit_code=$?
    log "audio_test_exit_code: ${audio_test_exit_code}"

    # whew ba/sh
    total="Unknown"
    merge_attempted="Unknown"
    grep -E "ffmpeg command line.*Gwo3pEH7hUE" process_A.yt_dlp.log || grep -E "ffmpeg command line.*Gwo3pEH7hUE" process_B.yt_dlp.log || merge_attempted="False" && merge_attempted="True"

    if [ "${output_file_count}" -eq 2 ];
    then
        if [ "${merge_attempted}" = "True" ];
        then
            automerge="fail"
        elif [ "${merge_attempted}" = "False" ];
        then
            automerge="None"
        fi
    elif [ "${output_file_count}" -eq ${expected_output_file_count} ];
    then
        if [ "${merge_attempted}" = "True" ];
        then
            automerge="PASS"
        elif [ "${merge_attempted}" = "False" ];
        then
            echo "NotImplementedError(3 files, but no merge attempted?)"; exit 1
        fi
    else
        echo "NotImplementedError"; exit 1
    fi


    if [ "${output_file_count}" -eq 3 ];
    then
        ffmpeg_test_file youtube__Gwo3pEH7hUE.mp4
        automerged_file_ffmpeg_test_exit_code="$?"
        if [ "${automerged_file_ffmpeg_test_exit_code}" -eq 0 ];
        then
            total="PASS"
        fi
    else
        total="fail"
    fi

    result_string="VIDEO:$(boolish ${video_test_exit_code})__AUDIO:$(boolish ${audio_test_exit_code})__AUTOMERGE:${automerge}__MANUALMERGE:$(boolish ${ffmpeg_manual_merge_exit_code})__TOTAL:${total}"
    #log "\nresult_string: ${result_string}"

    result_folder="${temp_dir}___${result_string}"
    cd ..
    mv -vi "${temp_dir}" "${result_folder}"

    log "\nINFO: results written to: $(readlink -f "${result_folder}")"
fi


# cases:
#
#    1. "nobody merged"
#       B: locks and starts writing youtube__Gwo3pEH7hUE.f160.mp4
#       A: BlockingIOError trying to lock youtube__Gwo3pEH7hUE.f160.mp4
#       A: locks and starts downloading youtube__Gwo3pEH7hUE.f139.m4a
#       B: BlockingIOError trying to lock youtube__Gwo3pEH7hUE.f139.m4a
#       B: does not attempt to merge since B did not download the audio track
#       A: does not attempt to merge since A did not download the video track
#       1a. youtube__Gwo3pEH7hUE.f160.mp4 and youtube__Gwo3pEH7hUE.f139.m4a exist
#               one or both is corrupt
#
#       Result: youtube__Gwo3pEH7hUE.f160.mp4 and youtube__Gwo3pEH7hUE.f139.m4a exist, but:
#               $ ffmpeg -y -loglevel repeat+info -i file:youtube__Gwo3pEH7hUE.f160.mp4 -i file:youtube__Gwo3pEH7hUE.f139.m4a -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart file:youtube__Gwo3pEH7hUE.temp.mp4
#               file:youtube__Gwo3pEH7hUE.f160.mp4: Invalid data found when processing input
#       So, somehow youtube__Gwo3pEH7hUE.f160.mp4 got corrupted.

