#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;

use POSIX;

# Author: Pavel Odintsov
# pavel.odintsov@gmail.com

# TODO: integrate net_cls support
# mount -t cgroup -o net_cls none /mnt/       
# mkdir /mnt/101          
# echo $$ > /mnt/101/tasks
# echo 0x100001 > /mnt/101/net_cls.classid 
# tc qdisc add dev eth0 root handle 10: htb
# tc class add dev eth0 parent 10: classid 10:1 htb rate 1mbit
# tc filter add dev eth0 parent 10: protocol ip prio 10 handle 1: cgroup
# vzctl start 101

my $hostname = `hostname`;
chomp $hostname;

my $use_hashed_filter = 0;

if ($hostname =~ /^evo0/ or $hostname =~ /^evo12/ or $hostname =~ /^evo10/) {
    $use_hashed_filter = 1
}

my $shaper_disabled = 0;

#if ($hostname =~ /^evo12/) {
#    $shaper_disabled = 1;
#}

# Никакого шейпера для технод
if ($hostname =~ m/^technode/) {
    $shaper_disabled = 1;
}

# Хэш, в которому нас хранится маппинга CTID и номера класса, котрый ему соответствует
my $ctid_class_mapping = {};

# А тут мы храним скорости в килобитах
my $ctid_speed_mapping = {};

# our потому что может использоваться в конфиге 
my $ve_config_path = '/etc/vz/conf';

my $main_network_interface = get_main_network_interface();
chomp $main_network_interface;

unless ($main_network_interface) {
    die "Can't get main network interface";
}

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

# В этот спец файлик мы будем сохранять маппинг номеров CTID и соотвествующих им номеров хендлов классов
my $shaper_data_path = "/var/lib/fastvps_shaper.dat";

my @all_container_subnets = (); 

# Собираем список всех  /24, из которых у нас используются IP на данной ноде
if ($use_hashed_filter) {
    @all_container_subnets = get_all_containers_subnets();
}   

# Настраиваем шейпер
tune_shaper();

# Дампим хэш соотвествия CTID номеру класса
open my $shaper_data_handle, '>', "/var/lib/fastvps_shaper.dat";
for my $key (sort keys %$ctid_class_mapping) {
    print {$shaper_data_handle} "$key $ctid_class_mapping->{$key} $ctid_speed_mapping->{$key}\n";
}

close $shaper_data_handle;

###
### Далее идут лишь объявления функций
###

# Выполнить команду в шелле
sub execute {
    my $command = shift;

    print "Starting to execute command: $command\n" if $DEBUG;
    my $output = `$command 2>&1`;

    if ($?) {
        warn "Cammand '$command' failed with error:\n$output\n";
        return 0;
    }

    return 1;
}

# Получить список IP для контейнера по его CTID
sub get_container_ips {
    my $ctid = shift;

    my @ips = ();

    my $config_path = "$ve_config_path/$ctid.conf";
    my $open_result = open my $ct_config, '<', $config_path;

    unless ($open_result) {
        warn "Can't open config for $ctid $!";
        return @ips;
    }

    foreach(<$ct_config>){
        if (/^IP_ADDRESS="(.*?)"/) {
            @ips = split /\s+/, $1;
        }
    }

    return @ips;
}

sub get_all_containers_subnets {
    my @all_containers_ips = get_all_containers_ips();

    my $subnets = {};

    for my $ip (@all_containers_ips) {
        if ($ip =~ /::/) {
            # skip ipv6
            next;
        }

        # Отрезаем первые три октета, это и будет наш адрес сети /24
        if ($ip =~ /^(\d+\.\d+\.\d+)\.\d+$/) {
            my $network_address = "$1.0";
            $subnets->{ $network_address }++; 
        } else {
            warn "Very strange IP, can't parse: $ip";
        }
    }

    return keys %$subnets;
}

sub get_all_containers_ips {
    my @ips = ();

    my @all_containers = get_all_containers_list();

    for my $ctid (@all_containers) {
        my @current_container_ips = get_container_ips($ctid);
        push @ips, @current_container_ips;
    } 

    return @ips;
}

sub init_shaper {
    # Инициализация шейпера
    for my $if ($internal_network_interface, $main_network_interface) {
        # Удаляем рутовые кудиски, они все вложенные кудиски снесут за собой
        execute("/sbin/tc qdisc del dev $if root");
        # А вообще, такое ощущение, что он нахрен сносит вообще все, что было! Фильтры и классы в том числе! 
    }

    # Если для машины по тем или иным причинам отключен шейпер, то заканчиваем работу скрипта именно здесь
    if ($shaper_disabled) {
        die "Shaper disabled for this server completely!";
    }

    # Так как нам нужна полная rate всех контейнеров, мы должны ее рассчитать обойдя все контейнеры
    my $total_conatiners_rate = get_total_containers_rate();

    for my $if ($internal_network_interface, $main_network_interface) {
        # Теперь создаем корневой кудиск
        # нуль в default означает, что никакие правила на него не накладываются и летит он свободно! 
        # An optional parameter with every HTB qdisc object, the default default is 0, which cause any
        # unclassified traffic to be dequeued at hardware speed, completely bypassing any of the classes attached to the root qdisc.

        # Явно задаем r2q, чтобы избежать: HTB: quantum of class 10001 is big. Consider r2q change
        # r2q DRR quantums are computed as rate in Bps/r2q {10} Источник: tc class add htb help

        # Источник: http://forum.nag.ru/forum/index.php?showtopic=48277
        # quantum = rate / r2q
        # mtu ≤ quantum ≤ 60000
        # quantum is small => RATE / R2Q < MTU
        # quantum is big => RATE / R2Q > 60000

        # В нашем случае: 30 000 000 / 3000 =  10000, что примерно ок

        execute("/sbin/tc qdisc add dev $if root handle 1: htb default 0 r2q 3000");
        
        # Что такое burst?
        # burst bytes
        # Amount of bytes that can be burst at ceil speed, in excess of the configured rate.
        # Should be at least as high as the highest burst of all children.
        # То есть он должен быть равен лимиту скорости для класса, зачем нам врубать шейпинг когда там летит меньше трафика?

        # Burst у родительского класса и дчернего должен быть в идеале равный!
        # Но ни в коем случае не МЕНЬШЕ чем у дочернего!!!
    
        # Note: The burst and cburst of a class should always be at least as high as that of any of it children.
        # When you set burst for parent class smaller than for some child then you should expect the parent class
        # to get stuck sometimes (because child will drain more than parent can handle). HTB will remember these
        # negative bursts up to 1 minute."  
        # (c) http://luxik.cdi.cz/~devik/qos/htb/manual/userg.htm

        # Созадем корневой класс, в него ничего не заворчивается, просто он родительский для вложенных
        # У нас гигабитный линк, 1000 мегабит
        # my $link_speed = 1000;

        # С rate оказывается все сложно, это вовсе не скорость линка, а должно быть суммой rate всех подклассов
        # Notes: Packet classification rules can assign to inner nodes too. Then you have to attach other filter list to inner node.
        # Finally you should reach leaf or special 1:0 class. The rate supplied for a parent should be the sum of the rates of its children.
        # Источник: http://luxik.cdi.cz/~devik/qos/htb/manual/userg.htm
        # http://forum.nag.ru/forum/index.php?showtopic=91342&view=findpost&p=924399

        my $rate = $total_conatiners_rate . "kbit";
        # Convert to kilobytes
        my $burst = 100;
        $burst = $burst . 'k';

        execute("/sbin/tc class add dev $if parent 1: classid 1:1 htb rate $rate burst $burst");

        if ($use_hashed_filter) {
            # Создаем корневой фильтр для IPv4 трафика
            my $res_root_filter_add = execute("/sbin/tc filter add dev $if parent 1:0 prio 10 protocol ip u32");
    
            #unless ($res_root_filter_add) {
            #    next CONTAINERS_LOOP;
            #}   

            my $number_of_subnets = scalar @all_container_subnets;
    
            # Создаем фильтр для сетей, divisor задает число элементов в хэше
            # divisor
            # Can be used to set a different hash table size, available from
            # kernel 2.6.39 onwards.  The specified divisor must be a power
            # of two and cannot be larger than 65536. 

            # divisor всегда должен быть степенью двойки!
            my $divisor = 0;

            # Считаем логарифм от числа подсетей 
            my $logarithm = log2($number_of_subnets);

            if ($logarithm =~ /^\d+$/) {
                # нам повезло и число сетей - эт остепень двойки
                $divisor = $number_of_subnets
            } else {
                # Используем округление вверх, чтобы получить ближайшее число больше текущего, но являющеесе степенью двойки
                my $exponent = POSIX::ceil($logarithm);
                $divisor = 2 ** $exponent;
            }   

            # Я думаю, 1000 сетей /24 вполне достаточно, надеюсь, у нас не будет больше на одной ноде
            #my $subnet_filter_handle = "1000";
            #my $subnet_filter_handle_hex = convert_to_hex( $subnet_filter_handle );
 
            #my $res_subnet_filter_add = 
            #    execute("/sbin/tc filter add dev $if parent 1:0 protocol ip prio 10 handle $subnet_filter_handle_hex: u32 divisor $divisor");

            #unless ($res_subnet_filter_add) {
            #    next CONTAINERS_LOOP;
            #}

            # Создаем хэши на 256 элементов для каждой сетки
            for (my $subnet_number = 1; $subnet_number <= $number_of_subnets; $subnet_number++) {
                my $subnet_number_as_hex = convert_to_hex( $subnet_number );
        
                my $subnet_number_minus_one = $subnet_number - 1;
                my $subnet_number_minus_one_hex = convert_to_hex( $subnet_number_minus_one );

                # handle должны быть в hex формате
                # http://linux-tc-notes.sourceforge.net/tc/doc/cls_u32.txt
                # Valid filter item handles range from 1 to ffe hex.

                my $res_ip_filter_add =
                    execute("/sbin/tc filter add dev $if parent 1:0 prio 10 handle $subnet_number_as_hex: protocol ip u32 divisor 256");

                #unless ($res_ip_filter_add) {
                #
                #}

                # dst or src
                my $packet_direction = '';
                if ($if eq $main_network_interface) {
                    $packet_direction = 'src';
                } else {
                    $packet_direction = 'dst';
                }

                my $address_shift = 0;

                # Смещения адреса получателя и отправителя разные! Их также нужно варировать!
                # Матчасть: http://forum.nag.ru/forum/index.php?showtopic=74688&view=findpost&p=704014
                # https://ru.wikipedia.org/wiki/IP#.D0.92.D0.B5.D1.80.D1.81.D0.B8.D1.8F_4_.28IPv4.29
                if ($packet_direction eq 'src') {
                    $address_shift = 12;
                } else {
                    $address_shift = 16;
                }

                # 800:: означает, что мы добавляем обработку класс в корневой фильтр
                my $res_subnet_level_classificator_res = execute("/sbin/tc filter add dev $if parent 1:0 protocol ip prio 10 u32 ht 800:: " . 
                    # Если убрать эту штуку, поидее, оно начнет работать не весь трафик
                    # "ht $subnet_filter_handle_hex:$subnet_number_minus_one_hex " .     
                    "match ip $packet_direction $all_container_subnets[$subnet_number_minus_one]/24 " . 
                    "hashkey mask 0x000000ff at $address_shift " . 
                    "link $subnet_number_as_hex:");

                #my $res_ip_level_classificator_res = execute("/sbin/tc filter add dev $if parent 1:0 protocol ip prio 100 u32 ht 800:: " .
                #    "match ip $packet_direction 159.253.16.0/21 hashkey mask 0x00000700 at 16 link $subnet_filter_handle_hex:");
            } 
        }   
    }
}

# Получаем список всех контейнерво КРОМЕ служебных
sub get_all_containers_list {
    my @all_containers = `/usr/sbin/vzlist -H1`;
    chomp @all_containers;

    my @client_containers = ();

    for my $ct (@all_containers) {
        $ct =~ s/^\s+//g;
        $ct =~ s/\s+$//g;

        # filter tecnical containers on PCS
        if ($ct == 1 or $ct == 50 or $ct =~ m/^100000$/) {
            next;
        }

        push @client_containers, $ct;
    }

    return @client_containers;
}

sub get_total_containers_rate {
    my @all_containers = get_all_containers_list();

    my $total_containers_rate = 0;

    CONTAINERS_LOOP:
    for my $ve (@all_containers) {
        my $ve_speed = get_speed_by_ctid($ve);

        unless ($ve_speed) {
            warn "Can't get VE speed for $ve\n";
            next;
        }

        $total_containers_rate += $ve_speed;
    }

    return $total_containers_rate;
}

# Активируем шейпинг
sub tune_shaper {
    my @all_containers = get_all_containers_list();

    # Инициализируем шейпер
    init_shaper();

    CONTAINERS_LOOP:
    for my $ve (@all_containers) {
        my $ve_speed = get_speed_by_ctid($ve);

        unless ($ve_speed) {
            warn "Can't get VE speed for $ve\n";
            next;
        } 

        my $global_classid_counter_hex = convert_to_hex($global_classid_counter);

        # Сохраняем маппинг CTID и класса в хэше
        $ctid_class_mapping->{$ve} = $global_classid_counter_hex;
        $ctid_speed_mapping->{$ve} = $ve_speed;

        # Конвертируем килобиты в килобайты
        my $burst = '100';
        $burst = $burst . 'k';

        # теперь надо создать класс под впску
        # формат classid: The minor node number for each classid must merely be a unique number between 1 and ffff in hexadecimal.
        # Источник: http://blog.edseek.com/~jasonb/articles/traffic_shaping/classes.html
        for my $if ($internal_network_interface, $main_network_interface) {
            execute("/sbin/tc class add dev $if parent 1:1 classid 1:$global_classid_counter_hex htb rate ${ve_speed}kbit ceil ${ve_speed}kbit burst $burst quantum 2500");

            my $res = execute("/sbin/tc qdisc add dev $if parent 1:$global_classid_counter_hex handle $global_classid_counter_hex: sfq perturb 10");
            unless ($res) {
                next CONTAINERS_LOOP;
            }

        }    

        # В фильтрыхендл класса также должен передаваться в hex формате
        # Из-за этого мы полгода насиловали клиентов, здесь класс должен быть также в hex!
        # http://forum.nag.ru/forum/index.php?showtopic=98376&view=findpost&p=1032590 

        my @container_ips = get_container_ips($ve);
        for my $ip (@container_ips) {
            #print "$ip $ve_speed\n";
    
            if ($ip =~ /^\d+\.\d+\.\d+\.\d+$/) {
                # IPv4
                add_filter($internal_network_interface, 'dst', $ip, 4, 1, $global_classid_counter_hex);
                add_filter($main_network_interface,     'src', $ip, 4, 1, $global_classid_counter_hex);
            } else {
                # IPv6
                add_filter($internal_network_interface, 'dst', $ip, 6, 2, $global_classid_counter_hex);
                add_filter($main_network_interface,     'src', $ip, 6, 2, $global_classid_counter_hex);
            }
        }
   
        # Увеличиваем счетчик для классида на 10
        $global_classid_counter += 10; 
    }

}

# Функция добавления фильтра в таблицу tc
sub add_filter {
    my ($interface, $direction, $ip, $proto, $priority, $classid_counter_hex) = @_;

    # Так как используется 16ричная нумерация для хендлов фильтров
    my $global_filter_counter_hex = convert_to_hex($global_filter_counter);

    my $first_type = '';
    my $second_type = '';

    my $prio_block = '';
    my $handle = '';

    # префикс 800 для IPv4 и 801 для IPv6 был определен по результатам тестов, при добавлении в виде ::counter
    if ($proto == 4) {
        $first_type = 'ip';
        $second_type = 'ip';
        $prio_block = "prio $priority";
        $handle = "handle 800::$global_filter_counter_hex";
    } elsif ($proto == 6) {
        $first_type = 'ipv6';
        $second_type = 'ip6';
        # Неактуально
        $prio_block = "prio $priority";
        $handle = "handle 801::$global_filter_counter_hex";
    }

    if ($use_hashed_filter) {
        if ($proto == 4)  {
            # Не нравится ему явно заданный handle!
            $handle = "";
            
            # Приоритет должен быть ниже чем у обычных лакаперов
            # $prio_block = "prio 100";

            my $last_ip_octet = get_last_ip_octet($ip); 
            my $last_ip_octet_hex = convert_to_hex($last_ip_octet);
   
            my $subnet_position_in_array = find_ip_position_in_array_of_subnet($ip, @all_container_subnets);
            my $subnet_position_in_array_as_hex = convert_to_hex($subnet_position_in_array);

            unless ($subnet_position_in_array) {
                warn "Can't get array id!!! Internal error!!!";
            }
 
            execute("/sbin/tc filter add dev $interface $handle protocol $first_type parent 1: $prio_block u32 ht $subnet_position_in_array_as_hex:$last_ip_octet_hex: match $second_type $direction \"$ip\" flowid 1:$classid_counter_hex");
        } else {
            $handle = "";
            execute("/sbin/tc filter add dev $interface $handle protocol $first_type parent 1: $prio_block u32 match $second_type $direction \"$ip\" flowid 1:$classid_counter_hex");
        } 
    } else {
        execute("/sbin/tc filter add dev $interface $handle protocol $first_type parent 1: $prio_block u32 match $second_type $direction \"$ip\" flowid 1:$classid_counter_hex");
    }

    $global_filter_counter++;
}

# На входе - айпи
# На выходе - позиция, где находится в массиве его сетка
sub find_ip_position_in_array_of_subnet {
    use Net::CIDR::Lite;

    my ($ip, @subnets_list) = @_;

    my $index = 1;
    for my $subnet (@subnets_list) {
        my $cidr = Net::CIDR::Lite->new($subnet . '/24');

        if ($cidr->find($ip)) {
            return $index;
        }

        $index++;
    }

    return 0;
}

# Логарифм по основанию 
sub log2 {
    my $value = shift;

    return log ($value) / log(2);
}

sub get_last_ip_octet{
    my $ip = shift;
    my @splitted_ip = split /\./, $ip;
    return $splitted_ip[-1];
}

sub convert_to_hex {
    my $number = shift;

    return sprintf("%x", $number);
}

sub get_main_network_interface {
    my $main_interface = '';

    my @route_show = `/sbin/ip route show`;
    chomp @route_show;

    for my $line (@route_show) {
        if ($line =~ /default via \d+\.\d+\.\d+\.\d+ dev (\w+)/) {
            $main_interface = $1;
        }
    }

    return $main_interface;
}

