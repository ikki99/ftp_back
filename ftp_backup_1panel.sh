#!/bin/bash
set -e  # 遇到错误时退出

# 设置远程目录(根据需要自行修改，建议后面换成服务器IP)
FTP_TARGET_DIR="${1:-1panel_0.0.0.0}"

# 配置信息
#备份的原目录，默认是1panel的默认备份目录，如果不是默认目录请修改
BACKUP_DIR="/opt/1panel/backup"
#远程FTP的信息，请自行修改
FTP_SERVER="$YOU_FTP_URL"
FTP_USER="$YOU_FTP_user"
FTP_PASS="$YOU_FTP_pwd"
#Email的发件人和收件人，用来接收通知，需要服务器安装sendmail并进行配置
EMAIL_FROM="you_email"
EMAIL_TO="you_email"
LOG_FILE="/var/log/backup.log"

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
