#!/bin/bash

# incus 容器 nezha 进程检测脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

declare -a INFECTED_CONTAINERS=()

do_scan() {
    INFECTED_CONTAINERS=()

    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN}  Incus 容器 nezha 进程检测工具${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns | grep -i ',RUNNING$' | cut -d',' -f1)

    if [ -z "$RUNNING_CONTAINERS" ]; then
        echo -e "${GREEN}没有正在运行的容器。${NC}"
        return 1
    fi

    TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

    COUNT=0
    while IFS= read -r container <&3; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

        # 第一次检测进程
        HIT1=$(incus exec "$container" -- sh -c '
            SELF=$$
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                if xargs -0 < "$f" 2>/dev/null | grep -qiE "nezha"; then
                    echo HIT; exit 0
                fi
            done
        ' </dev/null 2>/dev/null)

        if [ "$HIT1" = "HIT" ]; then
            # 进行二次扫描确认
            sleep 1
            HIT2=$(incus exec "$container" -- sh -c '
                SELF=$$
                for f in /proc/[0-9]*/cmdline; do
                    [ -f "$f" ] || continue
                    p="${f%/cmdline}"; p="${p#/proc/}"
                    [ "$p" = "$SELF" ] && continue
                    if xargs -0 < "$f" 2>/dev/null | grep -qiE "nezha"; then
                        echo HIT; exit 0
                    fi
                done
            ' </dev/null 2>/dev/null)

            if [ "$HIT2" = "HIT" ]; then
                INFECTED_CONTAINERS+=("$container")
                printf "\r${RED}[!] 二次确认发现异常: %-30s${NC}\n" "$container"
            else
                printf "\r${YELLOW}[-] 首次异常，二次确认正常 (已跳过): %-20s${NC}\n" "$container"
            fi
        fi
    done 3<<< "$RUNNING_CONTAINERS"

    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN}  扫描完成${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
        echo -e "${GREEN}所有容器均未检测到 nezha 进程，安全！${NC}"
        return 1
    fi

    echo -e "${RED}检测到 ${#INFECTED_CONTAINERS[@]} 个容器存在 nezha 进程:${NC}\n"
    for i in "${!INFECTED_CONTAINERS[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${INFECTED_CONTAINERS[$i]}"
    done
    echo ""
    return 0
}

# === 主流程 ===

while true; do
    do_scan
    
    echo -e "${CYAN}请选择操作:${NC}"
    echo -e "  ${YELLOW}1${NC}) 重新扫描"
    echo -e "  ${YELLOW}0${NC}) 退出"
    echo ""
    read -rp "请输入选项 [0-1]: " choice

    case $choice in
        1)
            continue
            ;;
        0)
            echo -e "${GREEN}退出。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${NC}\n"
            ;;
    esac
done
