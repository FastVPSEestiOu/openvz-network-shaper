#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;

# Author: Pavel Odintsov
# pavel.odintsov@gmail.com

# TODO:
# Почему-то у IPv6 фильтром нету хендлов, wtf?

# our потому что может использоваться в конфиге 
my $ve_config_path = '/etc/vz/conf';

my $main_network_interface = `/sbin/ip route show|grep default |awk '{print \$5}'`;
chomp $main_network_interface;

my $internal_network_interface = 'venet0';

my $DEBUG = 0;

# Счетчик для нумерации классов, увеличивается на 10 каждый раз
my $global_classid_counter = 10;

# Счетчик для нумерации хендлов фильтров, увеличивается на единицу каждый раз 
my $global_filter_counter = 1;

# здесь мы храним функцию получения скорости для VPS по CTID, она зовется: get_speed_by_ctid и получает 1 параметр - CTID
my $config_file_path = '/etc/fastvps_openvz_shaper_config';

my $config_loading_result = do $config_file_path;

unless ($config_loading_result) {
    die "Can't load conifg file $config_file_path";
}

# Настраиваем шейпер
tune_shaper();

###
### Далее идут лишь объявления функций
###

# Выполнить команду в шелле
sub execute {
    my $command = shift;

    print "Starting to execute command: $command\n" if $DEBUG;
    my $output = `$command 2>&1`;

    if ($?) {
        warn "Cammand '$command' failed with error: $output\n";
    }
}

# Получить список IP для контейнера по его CTID
sub get_container_ips {
    my $ctid = shift;

    my $config_path = "$ve_config_path/$ctid.conf";
    open my $ct_config, '<', $config_path or die "Can't open config  $!";

    my @ips = ();
    foreach(<$ct_config>){
        if (/^IP_ADDRESS="(.*?)"/) {
            @ips = split /\s+/, $1;
        }
    }

    return @ips;
}

sub init_shaper {
    # Инициализация шейпера
    for my $if ($internal_network_interface, $main_network_interface) {
        # Удаляем рутовые кудиски, они все вложеныне кудиски снесут за собой
        execute("/sbin/tc qdisc del dev $if root");
        # А вообще, такое ощущение, что он нахрен сносит вообще все, что было! Фильтры и классы в том числе! 

        # Теперь создаем корневой кудиск
        # нуль в default означает, что никакие правила на него не накладываются и летит он свободно! 
        # An optional parameter with every HTB qdisc object, the default default is 0, which cause any
        # unclassified traffic to be dequeued at ha    rdware speed, completely bypassing any of the classes attached to theroot qdisc.
        # Явно задаем r2q, чтобы избежать: HTB: quantum of class 10001 is big. Consider r2q change
        # r2q      DRR quantums are computed as rate in Bps/r2q {10} Источник: tc class add htb help

        # Источник: http://forum.nag.ru/forum/index.php?showtopic=48277
        # quantum = rate / r2q
        # mtu ≤ quantum ≤ 60000
        # quantum is small => RATE / R2Q < MTU
        # quantum is big => RATE / R2Q > 60000

        # В нашем случае: 30 000 000 / 3000 =  10000, что примерно ок

        execute("/sbin/tc qdisc add dev $if root handle 1: htb default 0 r2q 3000");

        # Созадем корневой класс, в него ничего не заворчивается, просто он родительский для вложенных
        execute("/sbin/tc class add dev $if parent 1: classid 1:1 htb rate 1000mbit burst 15k");
    }
}

# Активируем шейпинг
sub tune_shaper {
    my @all_containers = `/usr/sbin/vzlist -H1`;
    chomp @all_containers;

    @all_containers = map { s/^\s+//g; s/\s+$//g; $_ } @all_containers;

    # Инициализируем шейпер
    init_shaper();

    for my $ve (@all_containers) {
        my $ve_speed = get_speed_by_ctid($ve);

        unless ($ve_speed) {
            warn "Can't get VE speed for $ve\n";
            next;
        } 

        # теперь надо создать класс под впску
        for my $if ($internal_network_interface, $main_network_interface) {
            execute("/sbin/tc class add dev $if parent 1:1 classid 1:$global_classid_counter htb rate ${ve_speed}kbit ceil ${ve_speed}kbit burst 100k quantum 2500");

            execute("/sbin/tc qdisc add dev $if parent 1:$global_classid_counter handle $global_classid_counter: sfq perturb 10");
        }    

        my @container_ips = get_container_ips($ve);
        for my $ip (@container_ips) {
            #print "$ip $ve_speed\n";
    
            if ($ip =~ /^\d+\.\d+\.\d+\.\d+$/) {
                # IPv4
                add_filter($internal_network_interface, 'dst', $ip, 4);
                add_filter($main_network_interface,     'src', $ip, 4);
            } else {
                # IPv6
                add_filter($internal_network_interface, 'dst', $ip, 6);
                add_filter($main_network_interface,     'src', $ip, 6);
            }
        }
   
        # Увеличиваем счетчик для классида на 10
        $global_classid_counter += 10; 
    }

}

# Функция добавления фильтра в таблицу tc
sub add_filter {
    my ($interface, $direction, $ip, $proto) = @_;

    # Так как используется 16ричная нумерация для хендлов фильтров
    my $global_filter_counter_hex = sprintf("%x", $global_filter_counter);

    my $first_type = '';
    my $second_type = '';

    my $prio_block = '';
    my $handle = '';

    if ($proto == 4) {
        $first_type = 'ip';
        $second_type = 'ip';
        $prio_block = 'prio 1';
        $handle = "handle 800::$global_filter_counter_hex";
    } elsif ($proto == 6) {
        $first_type = 'ipv6';
        $second_type = 'ip6';
        # Неактуально
        $prio_block = '';
        $handle = '';
    }

    execute("/sbin/tc filter add dev $interface $handle protocol $first_type parent 1: $prio_block u32 match $second_type $direction \"$ip\" flowid 1:$global_classid_counter");

    # TODO баг с хендлами может быть здесь!!!
    # Для IPv6 нет хендла, не работает он :((( хз как вообще
    if ($proto == 4) {
        $global_filter_counter++;
    }
} 
