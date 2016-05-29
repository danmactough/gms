use lib qw(t/lib);
use GMSTest::Common 'pending_changes';
use GMSTest::Database;
use Test::More;
use Test::MockModule;

# We don't want this right now.

my $mockModel = new Test::MockModule ('GMS::Web::Model::Atheme');
$mockModel->mock ('session' => sub { });

my $mock = Test::MockModule->new('GMS::Atheme::Client');
$mock->mock('new', sub { });
$mock->mock('notice_staff_chan', sub {});


need_database 'pending_changes';

use ok 'Test::WWW::Mechanize::Catalyst' => 'GMS::Web';

my $ua = Test::WWW::Mechanize::Catalyst->new;

$ua->get_ok("http://localhost/", "Check root page");

$ua->get_ok("http://localhost/login", "Check login page works");
$ua->content_contains("Login to GMS", "Check login page works");

$ua->submit_form(
    fields => {
        username => 'admin01',
        password => 'admin001'
    }
);

$ua->content_contains("You are now logged in as admin01", "Check we can log in");

$ua->post_ok ('http://localhost/json/admin/approve_namespaces/submit',
    {
        approve_item => 'cns',
        approve_namespaces => '6 7',
        action_6 => 'approve',
    }
);

$ua->post_ok ('http://localhost/json/admin/approve_namespaces/submit',
    {
        approve_item => 'cns',
        approve_namespaces => '7',
        action_7 => 'reject',
    }
);

my $schema = GMS::Schema->do_connect;

my $rs = $schema->resultset('ChannelNamespace');

my $ns6 = $rs->find({ id => 6 });
my $ns7 = $rs->find({ id => 7 });

ok $ns6->status->is_active;
ok $ns7->status->is_deleted;

ok $ns6->active_change->change_type->is_admin;
ok $ns7->active_change->change_type->is_admin;


$ua->post_ok ('http://localhost/json/admin/approve_namespaces/submit',
    {
        approve_item => 'cns',
        approve_namespaces => 6,
        action_6 => 'approve'
    }
);

$ua->content_contains ("Can't approve a namespace that isn't pending approval", "Can't approve a namespace that isn't pending approval");

$ua->post_ok ('http://localhost/json/admin/approve_namespaces/submit',
    {
        approve_item => 'cns',
        approve_namespaces => 6,
        action_6 => 'reject'
    }
);

$ua->content_contains ("Can't reject a namespace not pending approval", "Can't reject a namespace not pending approval");

done_testing;
