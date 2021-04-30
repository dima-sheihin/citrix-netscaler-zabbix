#! /usr/bin/perl

use strict;
use warnings;
use vars qw(@ISA);
use utf8;
use POSIX;
use File::Temp qw(tempfile);
use Tiny;

my $WALK = "/usr/bin/snmpwalk";  # Бинарный файл
my $TMP  = "/tmp";               # Каталог для временных файлов

my %work;
my $res;

# От куда будем получать данные об актуальных Virtual Servers
$work{cluster}->{connection}{0}->{ip} = "172.16.10.1";
$work{cluster}->{connection}{1}->{ip} = "172.16.10.2";
$work{cluster}->{OID}                 = '.1.3.6.1.4.1.5951.4.1.3.1.1.1';
$work{cluster}->{OID_EXCLUDE}         = 'snmpv2-smi::enterprises.5951.4.1.3.1.1.1.';
$work{cluster}->{TMP_FILE_DROP}       = 1;

# Шаблон который будет использоватся
$work{template}->{name}  = 'Template_NetScaler_VPX_HAD_vServer';
$work{template}->{id}    = undef;
$work{template}->{macro} = '{$MACRO}'; # Макрос который будет использоватся

# Создании хоста
$work{create}->{interfaces}{0}->{ip}    = '{$NODE_1}'; #
$work{create}->{interfaces}{0}->{dns}   = '';          #
$work{create}->{interfaces}{0}->{useip} = 1;           # 0 - подключение по DNS имени; 1 - подключение по IP адресу
$work{create}->{interfaces}{0}->{port}  = 161;         # 
$work{create}->{interfaces}{0}->{type}  = 2;           # 1 - агент; 2 - SNMP; 3 - IPMI; 4 - JMX
$work{create}->{interfaces}{0}->{main}  = 1;           # 0 - не по умолчанию; 1 - по умолчанию

$work{create}->{interfaces}{1}->{ip}    = '{$NODE_2}';
$work{create}->{interfaces}{1}->{dns}   = '';
$work{create}->{interfaces}{1}->{useip} = 1;
$work{create}->{interfaces}{1}->{port}  = 161;
$work{create}->{interfaces}{1}->{type}  = 2;
$work{create}->{interfaces}{1}->{main}  = 0;

$work{create}->{hostgroup}->{name}      = 'NetScaler VPX HAD vServer';
$work{create}->{hostgroup}->{id}        = undef;

$work{create}->{z_proxy}->{name}        = 'Inet';
$work{create}->{z_proxy}->{id}          = undef;

my $zabbix;
eval {
  $zabbix = Zabbix::Tiny->new( server => "http://127.0.0.1/api_jsonrpc.php", user => "Admin", password => "123" );
  if ( ! defined $zabbix ) {
    print "fatal, exit\n";
    exit;
    }
  };
if ($@) {
  print "fatal, exit\n";
  exit;
  }

# Определим ID шаблона
if ( defined $work{template}->{name} ) {
  $res = undef;
  $res = shift $zabbix->do( 'template.get', filter => { host => [ $work{template}->{name} ] }, output => [ qw(templateid) ], );
  if ( defined $res->{templateid} ) {
    $work{template}->{id} = $res->{templateid};
    }
  }
if ( ! defined $work{template}->{id} ) {
  print "Error get template ID, from zabbix server, exit\n";
  exit;
  }

# Подгрузим хосты присоединенные к шаблону
my @hosts;
$res = undef;
$res = shift $zabbix->do( 'template.get', templateids => [ $work{template}->{id} ], selectHosts => 1, output => [ qw(hostid) ] );
if ( defined $res->{hosts} and $#{$res->{hosts}} >=0 ) {
  for my $n ( @{$res->{hosts}} ) {
    if ( defined $n->{hostid} ) {
      $work{zabbix}{template}{host}{ $n->{hostid} }->{template}=1;
      push @hosts, ($n->{hostid}) ;
      }
    }
  }

# Подгрузим маркос по каждому интересующему нас хосту
$res = undef;
$res = $zabbix->do( 'usermacro.get', hostids => [ @hosts ] );
if ( defined $res and $#{$res} >=0 ) {
  for my $host ( @{$res} ) {
    if ( defined $host->{value} and defined $host->{macro} and $host->{hostid} and $host->{macro} eq $work{template}->{macro} ) {
      $work{zabbix}{template}{host}{ $host->{hostid} }->{macro} = $host->{value};
      }
    }
  }

# Получим с cluster данные о сущьностях, зальем результат во временный файл, обработаем и зальем в структуру $work
if ( scalar keys %{ $work{cluster}->{connection} } >= 1 ) {
  foreach my $id ( keys $work{cluster}->{connection} ) {
    if ( defined $work{cluster}->{connection}{$id}->{ip} ) {
      get_res_snmp ( $id , $work{cluster}->{connection}{$id}->{ip} );
      }
    }
  }

# Нет ни одной виртуальной сущиности с обоих cluster
if ( scalar keys %{ $work{vserver} } == 0 ) {
  print "no virtual server \n";
  exit;
  }

# C одним из cluster node нет связи или что то не так с настройками, так как нет сущьностей на одном из них
foreach my $id ( keys %{ $work{cluster}->{connection} } ) {
  if ( ! defined $work{cluster}->{connection}{$id}->{count} ) {
    print "cluster node [$work{cluster}->{connection}{$id}->{ip}] no virtual server, server is null\n";
    exit;
    }
  if ( defined $work{cluster}->{connection}{$id}->{count} and $work{cluster}->{connection}{$id}->{count} == 0 ) {
    print "cluster node [$work{cluster}->{connection}{$id}->{ip}] no virtual server, server is null\n";
    exit;
    }
  }

# В обоих структурах zabbix и cluster есть хосты которые есть и там и там, найдм их и отмаркируем
foreach my $vserver ( keys %{ $work{vserver} } ) {
  foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {
    my $zabbix_macro = $work{zabbix}{template}{host}{$hostid}->{macro};
    if ( defined $vserver and defined $zabbix_macro and $vserver eq $zabbix_macro ) {
      $work{zabbix}{template}{host}{$hostid}->{result} = "hostfound";
      $work{vserver}{$vserver}->{result} = "hostfound";
      }
    }
  }

# Если в структуре zabbix не нашлись хосты, значит их нет на cluster, значит их нужно удалить
foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {
  if ( ! defined $work{zabbix}{template}{host}{$hostid}->{result} ) {
    $work{zabbix}{template}{host}{$hostid}->{result} = "hostdelete";
    }
  }

# Если в структуре cluster не нашлись некоторые хосты, значит это новые хосты которые нужно создать в zabbix
foreach my $vserver ( keys %{ $work{vserver} } ) {
  if ( ! defined $work{vserver}{$vserver}->{result} ) {
    $work{vserver}{$vserver}->{result} = "hostcreate";
    }
  }

# Удаление хостов из мониторинга, которые не нашлись, будет происходить только в том случае если нашлись хосты hostfound и нашлись хосты hostdelete
# Это делается для исключения случайного удаления всех хостов из мониторинга присоединенных к шаблону
my $flag_hostdelete = undef;
my $flag_hostfound  = undef;

foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {
  if ( defined $work{zabbix}{template}{host}{$hostid}->{result} and $work{zabbix}{template}{host}{$hostid}->{result} eq "hostdelete" ) { $flag_hostdelete++; }
  }

foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {
  if ( defined $work{zabbix}{template}{host}{$hostid}->{result} and $work{zabbix}{template}{host}{$hostid}->{result} eq "hostfound" ) { $flag_hostfound++;}
  }

# Процесс удаления хостов
if ( defined $flag_hostdelete and defined $flag_hostfound ) {
  foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{result} and $work{zabbix}{template}{host}{$hostid}->{result} eq "hostdelete" ) {
      my @del;
      push @del, $hostid;
      push @del, $hostid;
      my $delete = $zabbix->do( 'host.delete' , @del );
      print "host delete $hostid\n";
      }
    }
  }


# Перед началом создания хостов, нужно:

# Определить ID хост группы
if ( defined $work{create}->{hostgroup}->{name} ) {
  $res = undef;
  $res = shift $zabbix->do( 'hostgroup.get', filter => { name => [ $work{create}->{hostgroup}->{name} ] }, output => [ qw(groupid) ], );
  if ( defined $res->{groupid} ) {
    $work{create}->{hostgroup}->{id} = $res->{groupid};
    }
  }
if ( ! defined $work{create}->{hostgroup}->{id} ) {
  print "Error get hostgroup ID, from zabbix server, exit\n";
  exit;
  }

# Определить ID прокси сервера, учитываем что прокси сервера может и не быть
if ( defined $work{create}->{z_proxy}->{name} ) {
  $res = undef;
  $res = shift $zabbix->do( 'proxy.get', filter => { host => [ $work{create}->{z_proxy}->{name} ] }, output => [ qw(proxyid) ], );
  if ( defined $res->{proxyid} ) {
    $work{create}->{z_proxy}->{id} = $res->{proxyid};
    }
  }
if ( defined $work{create}->{z_proxy}->{name} and ! defined $work{create}->{z_proxy}->{id} ) {
  # Имя прокси сервера есть, но ID определить не удалось, сообщим и выдем
  print "Error get zabbix proxy ID, from zabbix server, exit\n";
  exit;
  }


# Убедимся что в мониторинге нет точно таких же хостов с тем же именем
foreach my $vserver ( keys %{ $work{vserver} } ) {

  if ( defined $work{vserver}{$vserver}->{result} and $work{vserver}{$vserver}->{result} eq "hostcreate") {
    my $vserver_name = $work{vserver}{$vserver}->{name};
    my $hostid  = shift $zabbix->do( 'host.get', filter => { host => [ $vserver_name ] }, output => [ qw(hostid) ] );
    if ( ! defined $hostid ) {
      $work{vserver}{$vserver}->{zabbix_host} = $vserver_name;
      }
    else {
      # Имя нашлось, прибавляем _1 и проверяем
      print "error test check host $vserver_name\n";
      my $vserver_name_1 = $vserver_name . "_1";

      my $hostid_1  = shift $zabbix->do( 'host.get', filter => { host => [ $vserver_name_1 ] }, output => [ qw(hostid) ] );
      if ( ! defined $hostid_1 ) {
        $work{vserver}{$vserver}->{zabbix_host} = $vserver_name_1;
        }
      else {
        # Имя нашлось, прибавляем _2 и проверяем
        print "error test check host $vserver_name and $vserver_name_1\n";
        my $vserver_name_2 = $vserver_name."_2";
        my $hostid_2  = shift $zabbix->do( 'host.get', filter => { host => [ $vserver_name_2 ] }, output => [ qw(hostid) ] );
        if ( ! defined $hostid_2 ) {
          $work{vserver}{$vserver}->{zabbix_host} = $vserver_name_2;
          }
        else {
          print "error test check host $vserver_name and $vserver_name_1 and $vserver_name_2\n";
          }
        }
      }
    }
  }

# Создадим массив с интерфейсами, при создании новых хостов настройки сетевых интерфейсов одинаковые
my @interfaces = ();
foreach my $id ( sort keys %{ $work{create}->{interfaces} } ) {
  my $ip    = $work{create}->{interfaces}{$id}->{ip};
  my $dns   = $work{create}->{interfaces}{$id}->{dns};
  my $useip = $work{create}->{interfaces}{$id}->{useip};
  my $port  = $work{create}->{interfaces}{$id}->{port};
  my $type  = $work{create}->{interfaces}{$id}->{type};
  my $main  = $work{create}->{interfaces}{$id}->{main};
  push @interfaces,{ type => $type, main => $main, useip => $useip, ip => $ip, dns => $dns, port => $port };
  }

# Создание хоста
foreach my $vserver ( keys %{ $work{vserver} } ) {
  if ( defined $work{vserver}{$vserver}->{result} and $work{vserver}{$vserver}->{result} eq "hostcreate" and defined $work{vserver}{$vserver}->{zabbix_host} ) {

    my $hostgroup   = $work{create}->{hostgroup}->{id};
    my $template    = $work{template}->{id};
    my $macro       = $work{template}->{macro};
    my $z_proxy_id  = $work{create}->{z_proxy}->{id};
    my $zabbix_host = $work{vserver}{$vserver}->{zabbix_host};

    $zabbix_host =~ (s/\#//g);
    $zabbix_host =~ (s/\://g);

    my $zabbix_name = $zabbix_host;
    $zabbix_name =~ (s/vsrv-/ /g);
    $zabbix_name =~ (s/vsrv_/ /g);
    $zabbix_name =~ (s/_/ /g);
    $zabbix_name =~ (s/  / /g);

    my $host_create;

    if ( defined $z_proxy_id ) {
      $host_create = $zabbix->do( 'host.create', host => $zabbix_host, name => $zabbix_name, interfaces => \@interfaces, groups => [ { groupid => $hostgroup } ], templates => [ { templateid => $template } ], macros => [ { macro => $macro, value => $vserver },], proxy_hostid => $z_proxy_id );
      }

    if ( ! defined $z_proxy_id ) {
      $host_create = $zabbix->do( 'host.create', host => $zabbix_host, name => $zabbix_name, interfaces => \@interfaces, groups => [ { groupid => $hostgroup } ], templates => [ { templateid => $template } ], macros => [ { macro => $macro, value => $vserver },], );
      }

    my $hostids;
    if ( defined $host_create ) {
      $hostids = ( shift $host_create->{hostids} );
      }
    if ( ! defined $hostids ) {
      print "Error create hosts\n";
      }
    print "New host ID $hostids\n";
    }
  select(undef,undef,undef, 0.20); # пауза
  }

select(undef,undef,undef, 0.20); # пауза



# Следующий большой этап изменения метрик

# так как часть метрик должна мониторится через один интерфейс а другая часть метрик через другой, при этом эти метрики находятся в одном шаблоне

# Получим item находящиеся внутри шаблона
$res = undef;
$res = $zabbix->do( 'item.get', templateids => [ $work{template}->{id} ], output => [ qw(itemid key_) ] );
if ( defined $res and $#{$res} >= 0 ) {
  for my $n ( @{$res} ) {
    if ( defined $n->{key_} and defined $n->{itemid} ) {
      $work{template}->{item}{ $n->{itemid} }->{key} = $n->{key_};
      push @{ $work{template}->{itemmass} }, $n->{itemid};
      }
    }
  }

# Получим роли LLD находящиеся внутри шаблона
$res = undef;
$res = $zabbix->do( 'discoveryrule.get', hostids => [ $work{template}->{id} ] , output => [ qw(hostid key_) ] );
if ( defined $res and $#{$res} >=0 ) {
  for my $n ( @{$res} ) {
    if ( defined $n->{key_} and defined $n->{itemid} ) {
      $work{template}->{lld}{ $n->{itemid} }->{key} = $n->{key_};
      push @{ $work{template}->{discoveryrulemass} }, $n->{itemid};
      }
    }
  }

# Получим прототипы метрик внутри LLD, находящиеся внутри шаблона
foreach my $ruleid ( sort keys %{ $work{template}->{lld} } ) {
  $res = undef;
  $res = $zabbix->do( 'itemprototype.get', discoveryids => [ $ruleid ] , output => [ qw(hostid itemid key_) ] );
  if ( defined $res and $#{$res} >=0 ) {
    for my $n ( @{$res} ) {
      if ( defined $n->{key_} and defined $n->{itemid} ) {
        $work{template}->{lld}{$ruleid}->{item}{$n->{itemid}}->{key} = $n->{key_};
        push @{ $work{template}->{itemprototypemass} }, $n->{itemid};
        }
      }
    }
  }


# Загрузим с мониторинга, с шаблона все хосты которые присоеденены у шаблону
my @hostsid;
delete $work{zabbix}{template}{host};
$res = undef;
$res = shift $zabbix->do( 'template.get', templateids => [ $work{template}->{id} ], selectHosts => 1, output => [ qw(hostid) ] );
if ( defined $res->{hosts} and $#{$res->{hosts}} >=0 ) {
  for my $n ( @{$res->{hosts}} ) {
    if ( defined $n->{hostid} ) {
      $work{zabbix}{template}{host}{ $n->{hostid} }->{template}=1;
      push @hostsid, ($n->{hostid}) ;
      }
    }
  }


# Получим интерфейсы, хостов
$res = undef;
$res = $zabbix->do( 'hostinterface.get', selectInterfaces => 1, hostids => [ @hostsid ], output => [ qw(hostid ip type) ] );
foreach my $host ( @$res ) {
  if ( defined $host->{hostid} and defined $host->{ip} and defined $host->{interfaceid} ) {
    $work{zabbix}{template}{host}{ $host->{hostid} }->{interface}{ $host->{interfaceid} }->{ip}   = $host->{ip};
    $work{zabbix}{template}{host}{ $host->{hostid} }->{interface}{ $host->{interfaceid} }->{type} = $host->{type};
    if ( $host->{ip} =~ /\{\$(.*)}/ ) {
      $work{zabbix}{template}{host}{ $host->{hostid} }->{interface}{ $host->{interfaceid} }->{key} = lc($1);
      }
    }
  }

# Получим метрики по хостам из шаблона
$res = undef;
$res = $zabbix->do( 'item.get', hostids => [ @hostsid ], filter => { templateid => $work{template}->{itemmass} }, output => [qw(hostid interfaceid itemid key_)] );
if ( defined $res and $#{$res} >=0 ) {
  for my $n ( @{$res} ) {
    if ( defined $n->{hostid} and defined $n->{interfaceid} and defined $n->{itemid} and defined $n->{key_} ) {
      $work{zabbix}{template}{host}{ $n->{hostid} }->{item}{ $n->{itemid} }->{interfaces} = $n->{interfaceid};
      $work{zabbix}{template}{host}{ $n->{hostid} }->{item}{ $n->{itemid} }->{key}        = $n->{key_};
      }
    }
  }


# Получим discoveryrule по хостам из шаблона
$res = undef;
$res = $zabbix->do( 'discoveryrule.get', hostids => [ @hostsid ], filter => { templateid => $work{template}->{discoveryrulemass} }, output => [ qw(hostid interfaceid itemid key_) ] );
if ( defined $res and $#{$res} >=0 ) {
  for my $n ( @{$res} ) {
    if ( defined $n->{hostid} and defined $n->{interfaceid} and defined $n->{itemid} and defined $n->{key_} ) {
      $work{zabbix}{template}{host}{ $n->{hostid} }->{rule}{ $n->{itemid} }->{interfaces} = $n->{interfaceid};
      $work{zabbix}{template}{host}{ $n->{hostid} }->{rule}{ $n->{itemid} }->{key}        = $n->{key_};
      }
    }
  }

# Получим item proto type по хостам из шаблона, внутри правила LLD
$res = undef;
$res = $zabbix->do( 'itemprototype.get', hostids => [ @hostsid ], filter => { templateid => $work{template}->{itemprototypemass} }, output => [ qw(hostid interfaceid itemid key_) ] );
if ( defined $res and $#{$res} >=0 ) {
  for my $n ( @{$res} ) {
    if ( defined $n->{hostid} and defined $n->{interfaceid} and defined $n->{itemid} and defined $n->{key_} ) {
      $work{zabbix}{template}{host}{ $n->{hostid} }->{itemprototype}{ $n->{itemid} }->{interfaces} = $n->{interfaceid};
      $work{zabbix}{template}{host}{ $n->{hostid} }->{itemprototype}{ $n->{itemid} }->{key}        = $n->{key_};
      }
    }
  }


# можно проводить анализ, правильности подключения метрик к интерфейсам
foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {

  # массив сетевых интерфейсов, конкретного хоста
  my %interface;
  foreach my $interfaceid ( keys %{ $work{zabbix}{template}{host}{$hostid}->{interface} } ) {
    $interface{$interfaceid}->{ip}  = $work{zabbix}{template}{host}{$hostid}->{interface}{$interfaceid}->{ip};
    $interface{$interfaceid}->{key} = $work{zabbix}{template}{host}{$hostid}->{interface}{$interfaceid}->{key};
    }

  # Простые метрики
  foreach my $itemid ( keys %{ $work{zabbix}{template}{host}{$hostid}->{item} } ) {
    my $key           = $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{key};
    my $key1          = undef;
    my $interfaceid   = $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{interfaces};
    my $interface_ip  = $interface{$interfaceid}->{ip};
    my $interface_key = $interface{$interfaceid}->{key};
    if ( $key =~ /^(node_\d).*/ ) { $key1 = $1; }
    if ( defined $key1 and defined $interface_key and $key1 ne $interface_key ) {
      # Ищем подходящий интерфейс
      foreach my $interfaceid ( keys %interface ) {
        if ( defined $interface{$interfaceid}->{ip} and defined $interface{$interfaceid}->{key} and defined $key1 and $key1 eq $interface{$interfaceid}->{key} ) {
          $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid} = $interfaceid;
          }
        }
      }
    }

  # Роли LLD
  foreach my $discoveryrule ( keys %{ $work{zabbix}{template}{host}{$hostid}->{rule} } ) {
    my $key           = $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{key};
    my $key1          = undef;
    my $interfaceid   = $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{interfaces};
    my $interface_ip  = $interface{$interfaceid}->{ip};
    my $interface_key = $interface{$interfaceid}->{key};
    if ( $key =~ /^(node_\d).*/ ) { $key1 = $1; }
    if ( ( defined $key1 and defined $interface_key and $key1 ne $interface_key ) or ( ! defined $interface_key ) ) {
      # Ищем подходящий интерфейс
      foreach my $interfaceid ( keys %interface ) {
        if ( defined $interface{$interfaceid}->{ip} and defined $interface{$interfaceid}->{key} and defined $key1 and $key1 eq $interface{$interfaceid}->{key} ) {
          $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid} = $interfaceid;
          }
        }
      }
    }

  # Прототипы данных внутри ролей LLD
  foreach my $itemprototype ( keys %{ $work{zabbix}{template}{host}{$hostid}->{itemprototype} } ) {
    my $key           = $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{key};
    my $key1          = undef;
    my $interfaceid   = $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{interfaces};
    my $interface_ip  = $interface{$interfaceid}->{ip};
    my $interface_key = $interface{$interfaceid}->{key};
    if ( $key =~ /^(node_\d).*/ ) { $key1 = $1; }
    if ( ( defined $key1 and defined $interface_key and $key1 ne $interface_key ) or ( ! defined $interface_key ) ) {
      # Ищем подходящий интерфейс
      foreach my $interfaceid ( keys %interface ) {
        if ( defined $interface{$interfaceid}->{ip} and defined $interface{$interfaceid}->{key} and defined $key1 and $key1 eq $interface{$interfaceid}->{key} ) {
          $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{new_interfaceid} = $interfaceid;
          }
        }
      }
    }
  }


# Маркируем хосты по которым будем производить изменения
foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {

  # item
  foreach my $itemid ( keys %{ $work{zabbix}{template}{host}{$hostid}->{item} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid} ) {
      $work{zabbix}{template}{host}{$hostid}->{update}=1;
      }
    }

  # Роли LLD
  foreach my $discoveryrule ( keys %{ $work{zabbix}{template}{host}{$hostid}->{rule} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid} ) {
      $work{zabbix}{template}{host}{$hostid}->{update}=1;
      }
    }

  # Прототипы данных внутри ролей LLD
  foreach my $itemprototype ( keys %{ $work{zabbix}{template}{host}{$hostid}->{itemprototype} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{new_interfaceid} ) {
      $work{zabbix}{template}{host}{$hostid}->{update}=1;
      }
    }
  }



# Производим изменения параметров метрик, ролей и прототипов
foreach my $hostid ( keys %{ $work{zabbix}{template}{host} } ) {

  if ( defined $work{zabbix}{template}{host}{$hostid}->{update} ) {
    print "Host $hostid\n";
    }


  # item
  foreach my $itemid ( keys %{ $work{zabbix}{template}{host}{$hostid}->{item} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid} ) {
      print "    fix item = $itemid   new interface = $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid}\n";
      $res = undef;
      $res = $zabbix->do( 'item.update', itemid => $itemid  , interfaceid => $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid} );
      if ( ! defined $res->{itemids} ) {
        print "    error fix item = $itemid    $work{zabbix}{template}{host}{$hostid}->{item}{$itemid}->{new_interfaceid}\n";
        }
      }
    }


  # Роли LLD
  foreach my $discoveryrule ( keys %{ $work{zabbix}{template}{host}{$hostid}->{rule} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid} ) {
      print "    fix rule = $discoveryrule  new interface = $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid}\n";
      $res = undef;
      $res = $zabbix->do( 'discoveryrule.update', itemid => $discoveryrule , interfaceid => $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid}  );
      if ( ! defined $res->{itemids} ) {
        print "    error fix discoveryrule $discoveryrule    $work{zabbix}{template}{host}{$hostid}->{rule}{$discoveryrule}->{new_interfaceid}\n";
        }
      }
    }

  # Прототипы данных внутри ролей LLD
  foreach my $itemprototype ( keys %{ $work{zabbix}{template}{host}{$hostid}->{itemprototype} } ) {
    if ( defined $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{new_interfaceid} ) {
      print "    fix prototype = $itemprototype   new interface = $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{new_interfaceid}\n";
      $res = undef;
      $res = $zabbix->do( 'itemprototype.update', itemid => $itemprototype  , interfaceid => $work{zabbix}{template}{host}{$hostid}->{itemprototype}{$itemprototype}->{new_interfaceid} );
      if ( ! defined $res->{itemids} ) {
        print "    error fix itemprototype = $itemprototype\n";
        }
      }
    }
  }


print "end\n";

#---------------------------------------------------------------------------------------------------------------



sub get_res_snmp {
my $id         = shift;
my $connection = shift;
my ( $f_handle , $f_name ) = tempfile ( "file-". 'XXXXXXXX' , DIR => "$TMP" , UNLINK => $work{cluster}->{TMP_FILE_DROP} );

system( "$WALK -v 2c -c public $connection $work{cluster}->{OID}  > $f_name" );

my ( $lines_count ) = split(/\s+/, `wc -l $f_name`);
if ( $lines_count < 2 ) {
  print "error cluster node [$connection] request broken\n";
  unlink( $f_name ) or die "Can't delete $f_name $!\n";
  return undef;
  }
if ( defined $f_name and -e $f_name ) {
  open (REQ, "$f_name") or die "Can't open $f_name";
  while (<REQ>) {
    chomp($_);
    my ( $vserver, $a , $b ,$name ) = split (" ", lc($_));
    $vserver =~ (s/$work{cluster}->{OID_EXCLUDE}//g);
    $name =~ (s/\"//g);
    $work{tmp}{vserver}{$vserver}->{name} = $name;
    }
  }
if ( scalar keys %{ $work{tmp}{vserver} } >= 0 ) {
  foreach my $vserver ( keys %{ $work{tmp}{vserver} } ) {
    $work{cluster}->{connection}{$id}->{count}++;
    $work{vserver}{$vserver}->{name} = $work{tmp}{vserver}{$vserver}->{name};
    }
  }
delete $work{tmp};
return 1;
}
# ------------------------------------------------------------------------
