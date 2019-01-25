#!/bin/sh

########################################################################
#
# FQDN
#
# Модуль для http://api.antizapret.info/group.php?data=domain
#
########################################################################

############################## Settings ################################

### Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
export ALT_NSLOOKUP=1
### Альтернативный DNS-сервер ($ONION_DNS_ADDR в ruantiblock.sh (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
export ALT_DNS_ADDR="8.8.8.8"
### Преобразование кириллических доменов в punycode (0 - off, 1 - on)
export USE_IDN=0
### Записи (ip, FQDN) исключаемые из списка блокировки (через пробел)
export EXCLUDE_ENTRIES="youtube.com"
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk amazonaws.com"
### Не оптимизировать SLD содержащие поддомены типа subdomain.xx(x).xx (.msk.ru .net.ru .org.ru .net.ua .com.ua .org.ua .co.uk и т.п.) (0 - off, 1 - on)
export OPT_EXCLUDE_3LD_REGEXP=0
### Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов
export SD_LIMIT=16
### В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
export BLLIST_MIN_ENTRS=30000
### Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
export STRIP_WWW=1

############################ Configuration #############################

export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
### Необходим gawk. Ибо "облегчённый" mawk, похоже, не справляется с огромным кол-вом обрабатываемых записей и крашится с ошибками...
AWK_CMD="awk"
WGET_CMD=`which wget`
if [ $? -ne 0 ]; then
    echo " Error! Wget doesn't exists" >&2
    exit 1
fi
WGET_PARAMS="--no-check-certificate -q -O -"
IDN_CMD=`which idn`
if [ $USE_IDN = "1" -a $? -ne 0 ]; then
    echo " Idn doesn't exists" >&2
    USE_IDN=0
fi
DATA_DIR="/opt/var/${NAME}"
export DNSMASQ_DATA_FILE="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA_FILE="${DATA_DIR}/${NAME}.ip"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"
### Источник блэклиста
AZ_FQDN_URL="http://api.antizapret.info/group.php?data=domain"

############################# Run section ##############################

$WGET_CMD $WGET_PARAMS "$AZ_FQDN_URL" | $AWK_CMD -v IDN_CMD="$IDN_CMD" '
    BEGIN {
        ### Массивы из констант с исключениями
        makeConstArray(ENVIRON["EXCLUDE_ENTRIES"], ex_entrs_array, " ");
        makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
        total_ip=0; total_fqdn=0;
    }
    ### Массивы из констант
    function makeConstArray(string, array, separator,  _split_array, _i) {
        split(string, _split_array, separator);
        for(_i in _split_array)
            array[_split_array[_i]]="";
    };
    ### Получение SLD из доменов низших уровней
    function getSld(val) {
        return substr(val, match(val, /[a-z0-9_-]+[.][a-z0-9-]+$/));
    };
    ### Запись в $DNSMASQ_DATA_FILE
    function writeDNSData(val) {
        if(ENVIRON["ALT_NSLOOKUP"] == 1)
            printf "server=/%s/%s\n", val, ENVIRON["ALT_DNS_ADDR"] > ENVIRON["DNSMASQ_DATA_FILE"];
        printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] > ENVIRON["DNSMASQ_DATA_FILE"];
    };
    ### Запись в $IP_DATA_FILE
    function writeIpsetEntries(array, set,  _i) {
        for(_i in array)
            printf "add %s %s\n", set, _i > ENVIRON["IP_DATA_FILE"];
    };
    ### Обработка ip и CIDR
    function checkIp(val, array2, counter) {
        if(!(val in ex_entrs_array)) {
            array2[val]="";
            counter++;
        };
        return counter;
    };
    ### Обработка FQDN
    function checkFQDN(val, array, cyr,  _sld, _call_idn) {
        sub(/[.]$/, "", val);
        sub(/^[\052][.]/, "", val);
        if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[0-9]?[.]/, "", val);
        if(val in ex_entrs_array) next;
        if(cyr == 1) {
            ### Кириллические FQDN кодируются $IDN_CMD в punycode ($AWK_CMD вызывает $IDN_CMD с параметром val, в отдельном экземпляре /bin/sh, далее STDOUT $IDN_CMD функцей getline помещается в val)
            _call_idn=IDN_CMD" "val;
            _call_idn | getline val;
            close(_call_idn);
        }
        ### Проверка на отсутствие лишних символов и повторы
        if(val ~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/) {
            ### SLD из FQDN
            _sld=getSld(val);
            ### Каждому SLD задается предельный лимит, чтобы далее исключить из очистки при сравнении с $SD_LIMIT
            if(val == _sld)
                sld_array[val]=ENVIRON["SD_LIMIT"];
            else {
            ### Обработка остальных записей низших ур-ней
                ### Пропуск доменов 3-го ур-ня вида: subdomain.xx(x).xx
                if(ENVIRON["OPT_EXCLUDE_3LD_REGEXP"] == "1" && val ~ /[.][a-z]{2,3}[.][a-z]{2}$/)
                    next;
                array[val]=_sld;
                ### Исключение доменов не подлежащих оптимизации
                if(_sld in ex_sld_array) next;
                ### Если SLD (полученный из записи низшего ур-ня) уже обрабатывался ранее, то счетчик++, если нет, то добавляется элемент sld_array[SLD] и счетчик=1 (далее, если после обработки всех записей, счетчик >= $SD_LIMIT, то в итоговом выводе остается только запись SLD, а все записи низших ур-ней будут удалены)
                if(_sld in sld_array) sld_array[_sld]++;
                else sld_array[_sld]=1;
            };
        };
    };
    {
        ### Отбор ip
        if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/)
            total_ip=checkIp($0, total_ip_array, total_ip);
        ### Отбор FQDN
        else if($0 ~ /^[a-z0-9.\052_-]+[.]([a-z]{2,}|xn--[a-z0-9]+)[.]?$/) {
            checkFQDN($0, total_fqdn_array, 0);
            total_fqdn++;
        }
        ### Отбор кириллических FQDN
        else if(ENVIRON["USE_IDN"] == "1" && $0 ~ /^([a-z0-9.-])*[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
            checkFQDN($0, total_fqdn_array, 1);
            total_fqdn++;
        };
    }
    END {
        output_fqdn=0; exit_code=0;
        ### Если кол-во обработанных записей менее $BLLIST_MIN_ENTRS, то код завершения 2
        if((total_ip + total_fqdn) < ENVIRON["BLLIST_MIN_ENTRS"])
            exit_code=2;
        else {
            ### Запись в $IP_DATA_FILE
            system("rm -f \"" ENVIRON["IP_DATA_FILE"] "\"");
            writeIpsetEntries(total_ip_array, ENVIRON["IPSET_IP_TMP"]);
            ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA_FILE
            system("rm -f \"" ENVIRON["DNSMASQ_DATA_FILE"] "\"");
            ### Чистка sld_array[] от тех SLD, которые встречались при обработке менее $SD_LIMIT (остаются только достигнувшие $SD_LIMIT) и добавление их в $DNSMASQ_DATA_FILE (вместо исключаемых далее субдоменов достигнувших $SD_LIMIT)
            if(ENVIRON["SD_LIMIT"] > 1) {
                for(j in sld_array) {
                    if(sld_array[j] < ENVIRON["SD_LIMIT"])
                        delete sld_array[j];
                    else {
                        output_fqdn++;
                        writeDNSData(j);
                    };
                };
            };
            ### Запись из total_fqdn_array[] в $DNSMASQ_DATA_FILE с исключением всех SLD присутствующих в sld_array[] и их субдоменов (если ENVIRON["SD_LIMIT"] > 1)
            for(k in total_fqdn_array) {
                if(ENVIRON["SD_LIMIT"] > 1 && total_fqdn_array[k] in sld_array)
                    continue;
                else {
                    output_fqdn++;
                    writeDNSData(k);
                };
            };
        };
        ### Запись в $UPDATE_STATUS_FILE
        printf "%s %s %s", total_ip, "0", output_fqdn > ENVIRON["UPDATE_STATUS_FILE"];
        exit exit_code;
    }'

exit $?
