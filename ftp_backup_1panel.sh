#!/bin/bash
set -e  # 遇到错误时退出

# 设置远程目录
FTP_TARGET_DIR="${1:-1panel_107.148.61.50}"

# 配置信息
BACKUP_DIR="/opt/1panel/backup"
FTP_SERVER="172.98.12.88"
FTP_USER="10w_bak"
FTP_PASS="wngx@9999"
EMAIL_FROM="ikkiwan99@gmail.com"
EMAIL_TO="wngx99@gmail.com"
LOG_FILE="/var/log/backup.log"

KEEP_BACKUPS=3  # 每个项目保留的备份数量

# 清除旧的日志文件
> "$LOG_FILE"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 获取本地文件列表和大小
get_local_files() {
    find "$BACKUP_DIR" -type f -printf "%P %s\n"
}

# 获取远程文件列表和大小
get_remote_files() {
    lftp -u "$FTP_USER,$FTP_PASS" "$FTP_SERVER" << EOF
    set ssl:verify-certificate no
    cd "$FTP_TARGET_DIR"
    glob -a
    quit
EOF
}

# 全局变量用于记录上传统计
TOTAL_SIZE=0
FILE_COUNT=0

# 修改上传函数
upload_files() {
    local START_TIME=$(date +%s)
    
    log "开始上传文件到 FTP 服务器"
    
    # 创建临时文件来存储上传信息
    UPLOAD_LOG=$(mktemp)
    
    lftp -u "$FTP_USER,$FTP_PASS" "$FTP_SERVER" << EOF | tee "$UPLOAD_LOG"
    set ssl:verify-certificate no
    set mirror:parallel-transfer-count 5
    set mirror:use-pget-n 5
    cd "$FTP_TARGET_DIR"
    mirror --reverse --only-newer --verbose=3 "$BACKUP_DIR" .
    bye
EOF
    
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    
    # 处理上传日志
    local TOTAL_SIZE=0
    local FILE_COUNT=0
    
    while IFS= read -r line; do
        if [[ $line =~ 传输文件\ \'(.*)\'$ ]]; then
            local file="${BASH_REMATCH[1]}"
            if [[ -f "$BACKUP_DIR/$file" ]]; then
                local size=$(stat -c %s "$BACKUP_DIR/$file")
                log "上传文件: $file ($(numfmt --to=iec-i --suffix=B --format="%.2f" $size))"
                TOTAL_SIZE=$((TOTAL_SIZE + size))
                FILE_COUNT=$((FILE_COUNT + 1))
            fi
        elif [[ $line =~ 已完成\ transfer\ \'(.*)\'\ \((.*)/s\)$ ]]; then
            local file="${BASH_REMATCH[1]}"
            local speed="${BASH_REMATCH[2]}"
            log "完成上传: $file (速度: $speed/s)"
        fi
    done < "$UPLOAD_LOG"
    
    # 删除临时文件
    rm "$UPLOAD_LOG"
    
    # 计算平均上传速度（字节/秒）
    local AVG_SPEED=0
    if [ $DURATION -gt 0 ]; then
        AVG_SPEED=$((TOTAL_SIZE / DURATION))
    fi
    
    log "上传完成. 总共上传 $FILE_COUNT 个文件, 总大小 $(numfmt --to=iec-i --suffix=B --format="%.2f" $TOTAL_SIZE)"
    log "上传用时: $DURATION 秒"
    log "平均上传速度: $(numfmt --to=iec-i --suffix=B --format="%.2f" $AVG_SPEED)/s"
    
    log "文件上传完成"
}

# 获取远程文件列表
get_remote_files() {
    lftp -u "$FTP_USER,$FTP_PASS" "$FTP_SERVER" << EOF
    set ssl:verify-certificate no
    cd "$FTP_TARGET_DIR"
    find . -type f
    quit
EOF
}
# 删除旧的远程备份文件
delete_old_backups() {
    log "开始检查并删除旧的远程备份文件"

    # 获取远程文件列表
    mapfile -t remote_files < <(get_remote_files)

    # 获取本地文件列表
    mapfile -t local_files < <(find "$BACKUP_DIR" -type f -printf "%P\n")

    # 创建关联数组来存储每个项目的文件
    declare -A project_files

    # 遍历远程文件，将它们分类到不同的项目中
    for file in "${remote_files[@]}"; do
        project=$(echo "$file" | cut -d'/' -f1-3)  # 假设项目名在路径的前三个部分
        project_files["$project"]+="$file "
    done

    # 检查每个项目的文件数量，如果超过限制就删除最旧的文件
    for project in "${!project_files[@]}"; do
        IFS=' ' read -ra files <<< "${project_files[$project]}"
        if [ ${#files[@]} -gt $KEEP_BACKUPS ]; then
            # 按照修改时间排序文件
            IFS=$'\n' sorted_files=($(printf "%s\n" "${files[@]}" | xargs -I {} lftp -u "$FTP_USER,$FTP_PASS" "$FTP_SERVER" -e "set ssl:verify-certificate no; cd $FTP_TARGET_DIR; ls -t {}; quit" | awk '{print $9}'))
            
            # 删除多余的旧文件
            for ((i=KEEP_BACKUPS; i<${#sorted_files[@]}; i++)); do
                file_to_delete="${sorted_files[i]}"
                if ! [[ " ${local_files[*]} " =~ " ${file_to_delete#./} " ]]; then
                    log "删除旧的远程文件: $file_to_delete"
                    lftp -u "$FTP_USER,$FTP_PASS" "$FTP_SERVER" << EOF
                    set ssl:verify-certificate no
                    cd "$FTP_TARGET_DIR"
                    rm "$file_to_delete"
                    quit
EOF
                fi
            done
        fi
    done

    log "完成检查和删除旧的远程备份文件"
}

# 发送邮件通知
send_email() {
    local subject="$1"
    local body="$2"
    (
        echo "Subject: $subject"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo
        echo -e "$body"
    ) | sendmail -f "$EMAIL_FROM" "$EMAIL_TO"
    log "已发送邮件通知: $subject"
}

# 主程序
main() {
    log "开始备份过程"
    log "使用的远程目录: $FTP_TARGET_DIR"
    
    upload_files
    delete_old_backups
    
    if [ $? -eq 0 ]; then
        log "备份完成并成功上传到 FTP 服务器"
        send_email "备份成功通知" "备份已成功完成并上传到 FTP 服务器。\n\n日志内容：\n$(cat "$LOG_FILE")"
    else
        log "备份失败"
        send_email "备份失败通知" "备份过程中发生错误。\n\n日志内容：\n$(cat "$LOG_FILE")"
    fi
    
    log "备份脚本执行完毕"
}

# 执行主程序
main
