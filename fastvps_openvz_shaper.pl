#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;

# TODO:
# Почему-то у IPv6 фильтром нету хендлов, wtf?

my $ve_config_path = '/etc/vz/conf';

my $main_network_interface = `/sbin/ip route show|grep default |awk '{print \$5}'`;
chomp $main_network_interface;

my $internal_network_interface = 'venet0';

my $DEBUG = 0;

my $distro = `cat /etc/redhat-release|awk '{print \$1}'`;
chomp $distro;

# Тут будет либо centos либо cloudlinux
$distro = lc $distro;

sub execute {
    my $command = shift;

    print "Starting to execute command: $command\n" if $DEBUG;
    my $output = `$command 2>&1`;

    if ($?) {
        warn "Cammand '$command' failed with error: $output\n";
    }
}

sub load_config_file_into_hash {
    my $file_name = shift;

    my $ct_config_hash = {};
    open my $ct_config, '<', $file_name or die "Can't open config  $!";

    foreach(<$ct_config>){
        if (/^\s*(\w+)="(.*?)"/) {
            my ($key, $value) = ($1, $2);

            if ($value =~ /\s+/) {
                $ct_config_hash->{$key} = [ split /\s+/, $value ];
            } else {
                $ct_config_hash->{$key} = $value;
            }

            if ($ct_config_hash->{'OOMGUARPAGES'} && $ct_config_hash->{'OOMGUARPAGES'} !~ /^\d+$/) {
                my ($barrier, $limit) = split /:/, $ct_config_hash->{'OOMGUARPAGES'};
                    
                if ($barrier != $limit) {
                    die "OOMGUARPAGES barrier and limit is not equal for $file_name\n";
                }

                $ct_config_hash->{'OOMGUARPAGES'} = $limit;
            }

            if (ref $ct_config_hash->{'IP_ADDRESS'} ne 'ARRAY') {
                # это будет в случае, если IP адрес один, для унификации положим его в массив
                $ct_config_hash->{'IP_ADDRESS'} = [ $ct_config_hash->{'IP_ADDRESS'} ];
            }
        }
    }

    return $ct_config_hash;
}

my $openvz_plan_binding = {
    '400'  => 'ovz-1',
    '800'  => 'ovz-2',
    '1200' => 'ovz-3',
    '1600' => 'ovz-4',
    '2000' => 'ovz-5',
    '2400' => 'ovz-6',
    '1500' => 'vip-ovz',
    '8000' => 'fps-1',
    '16000'=> 'fps-2',
    '24000'=> 'fps-3',
};

my $plan_speed_binding = {
    'ovz-1'   => '15000',
    'ovz-2'   => '15000',
    'ovz-3'   => '20000',
    'ovz-4'   => '20000',
    'ovz-5'   => '25000',
    'ovz-6'   => '25000',
    'vip-ovz' => '30000',
    'fps-1'   => '50000',
    'fps-2'   => '50000',
    'fps-3'   => '50000',
};

sub get_plan_name_by_oomguarpages {
    my $oom_guar_pages = shift;

    # А теперь мегаизврат, по объему гарантированной памяти определяем тариф
    if ($openvz_plan_binding->{$oom_guar_pages}) {
        return $openvz_plan_binding->{$oom_guar_pages};
    } else {
        return '';
    }
}

my @all_containers = `vzlist -H1`;
chomp @all_containers;

@all_containers = map { s/^\s+//g; s/\s+$//g; $_ } @all_containers;

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

# Начнем с десятки 
my $global_classid_counter = 10;
my $global_filter_counter = 1;

for my $ve (@all_containers) {
    # это служебный контейнер на Parallels Cloud Server, сама нода
    if ($ve eq '1') {
        next;
    }

    # Это VE для Repair режима, они хорошие, их не надо лимитировать
    # Примеры VEID: 10000000, 10000001 ... 
    if ($ve =~ m/^100000$/) {
        next;
    }

    my $ve_config = load_config_file_into_hash("$ve_config_path/$ve.conf");
    my $plan_name = '';

    if ($distro eq 'centos') {
        # Для центоса конфиг получаем эвристически 
        my $oom_in_megabytes = $ve_config->{OOMGUARPAGES} * 4/1024;
        $plan_name = get_plan_name_by_oomguarpages($oom_in_megabytes);
    } elsif ($distro eq 'cloudlinux') {
        # То есть всех срезаем на 50 мегабит
        $plan_name = 'fps-1';
    }

    unless ($plan_name) {
        warn "Can't get plan name for $ve\n";
        next;
    }

    my $ve_speed = $plan_speed_binding->{$plan_name};

    unless ($ve_speed) {
        die "Can't get VE speed for plan $plan_name\n";
    } 


    # теперь надо создать класс под впску
    for my $if ($internal_network_interface, $main_network_interface) {
        execute("/sbin/tc class add dev $if parent 1:1 classid 1:$global_classid_counter htb rate ${ve_speed}kbit ceil ${ve_speed}kbit burst 100k quantum 2500");

        execute("/sbin/tc qdisc add dev $if parent 1:$global_classid_counter handle $global_classid_counter: sfq perturb 10");
    }    

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

        # Для IPv6 нет хендла, не работает он :((( хз как вообще
        if ($proto == 4) {
            $global_filter_counter++;
        }
    } 

    for my $ip (@{$ve_config->{IP_ADDRESS}}) {
        #print "$ip $ve_speed\n";
    
        if ($ip =~ /^\d+\.\d+\.\d+\.\d+$/) {
            add_filter($internal_network_interface, 'dst', $ip, 4);
            add_filter($main_network_interface,     'src', $ip, 4);
        } else {
            add_filter($internal_network_interface, 'dst', $ip, 6);
            add_filter($main_network_interface,     'src', $ip, 6);
        }
    }
   
    # Увеличиваем счетчик для классида на 10
    $global_classid_counter += 10; 
}

