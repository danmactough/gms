package GMS::Web::Controller::Admin::Staff;

use strict;
use warnings;
use base qw (GMS::Web::TokenVerification);

use GMS::Domain::Group;

use TryCatch;
use GMS::Exception;

=head1 NAME

GMS::Web::Controller::Admin::Staff - Controller for GMS::Web

=head1 DESCRIPTION

This controller contains handlers for the staff pages.

=head1 METHODS

=head2 single_group

Chained method to select a single group. Similar to
L<GMS::Web::Controller::Group/single_group>, but searches all groups, not those
for which the user is a contact.

=cut

sub single_group :Chained('/admin/base') :PathPart('group') :CaptureArgs(1) {
    my ($self, $c, $group_id) = @_;

    my $group_row = $c->model('DB::Group')->find({ id => $group_id });

    try {
        my $session = $c->model('Atheme')->session;

        if ($group_row) {
            my $group = GMS::Domain::Group->new ( $session, $group_row );
            $c->stash->{group} = $group;
        } else {
            $c->detach('/default');
        }
    }
    catch (RPC::Atheme::Error $e) {
        $c->stash->{error_msg} = "The following error occurred when attempting to communicate with atheme: " . $e->description . ". Data displayed below may not be current.";
        if ($group_row) {
            $c->stash->{group} = $group_row;
        } else {
            $c->detach('/default');
        }
    }
}

=head2 account

Chained method to select an account.

=cut

sub account :Chained('/admin/base') :PathPart('account') :CaptureArgs(1) {
    my ($self, $c, $account_id) = @_;

    my $pass = $c->req->params->{__auth_pass};
    my $user = $c->user->account->accountname;

    if ($pass) {
        if (!$c->authenticate({ username => $user, password => $pass })) {
            $c->stash->{error_msg} = 'Incorrect password.';
            $c->stash->{template} = 'get_password.tt';
            $c->detach;
        }
    }

    my $account = $c->model('Accounts')->find_by_uid ( $account_id );

    try {

        my $atheme_conf = $c->config->{'Model::Atheme'};

        my $session = RPC::Atheme::Session->new(
            $atheme_conf->{hostname},
            $atheme_conf->{port},
            $atheme_conf->{service},
            {
                authcookie => $c->user->authcookie,
                username   => $c->user->account->accountname,
                persistent => 1,
            }
        );

        my $client = GMS::Atheme::Client->new ($session);

        if ($account) {
            my $info = $client->info('?' . $account->uuid);

            $c->stash->{info} = $info;
        }

        if ($account && ref $account eq 'GMS::Schema::Result::Account') {
            $c->stash->{error_msg} = "An error occurred when attempting to communicate with atheme. Data displayed below may not be current.";
        }
    }
    catch (RPC::Atheme::Error $e) {
        if ($e->code == RPC::Atheme::Error::badauthcookie) {
            # If we wound up here, we need the user's password to get a new
            # auth cookie for the user's Atheme session.

            $c->stash->{template} = 'get_password.tt';
            $c->detach;
        }

        # TODO - check this will happen ?
        # TODO - don't tell the user what the error is, dummy
        $c->stash->{error_msg} = "The following error occurred when attempting to communicate with atheme: " . $e->description . ".";
    }

    if ($account) {
        $c->stash->{account} = $account;
    } else {
        $c->detach('/default');
    }
}

=head2 search_groups

Presents the form to search groups.

=cut

sub search_groups :Chained('/admin/base') :PathPart('search_groups') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = "admin/search_groups.tt";
}

=head2 do_search_groups

Performs a search with the criteria provided and displays the groups found.

=cut

sub do_search_groups :Chained('/admin/base') :PathPart('search_groups/submit') :Args(0) {
    my ($self, $c) = @_;

    my $p = $c->request->params;
    my $group_rs = $c->model("DB::Group");
    my $mode = $p->{mode}; #1 - At least 1 criterion must be satisfied (OR)
                           #2 - All criteria must be satisfied (AND)
    my (@search, @join, $page);

    my $current_page = $p->{current_page} || 1;
    my $next = $p->{next};

    if ($next && $next eq 'Next page') {
        $page = $current_page + 1;
    } elsif ($next && $next eq 'Previous page') {
        $page = $current_page - 1;
    } elsif ($next && $next eq 'First page') {
        $page = 1;
    } elsif ($next && $next eq 'Last page') {
        $page = $p->{last_page};
    } else {
        $page = $p->{page} || $current_page;
    }

    if ($p->{group_name}) {
        my $group_name = $p->{group_name};
        $group_name =~ s#_#\\_#g; #escape _ so it's not used as a wildcard.

        push @search, 'group_name' => { 'ilike', '%' . $group_name . '%' };
    }

    if ($p->{gc_accname}) {
        my $accname = $p->{gc_accname};
        my $account_search;

        try {
            my $accounts = $c->model('Accounts');
            my $account = $accounts->find_by_name ( $accname );
            my $uid = $account->id;

            $account_search = { 'account.uuid' => $uid };

            if (ref $account eq 'GMS::Schema::Result::Account') {
                $c->stash->{error_msg} = "An error occurred when attempting to communicate with atheme. Data displayed below may not be current.";
                $accname =~ s#_#\\_#g;
                $account_search = { 'account.accountname' => { 'ilike', $accname } };
            }
        }
        catch (GMS::Exception $e) {
            # Prevent returning results if we're doing AND search,
            # since the account did not exist.
            $account_search = { "account.accountname" => 0 };
        }

        push @search, $account_search;
        push @join, { 'group_contacts' => [ { 'contact' => 'account' } ] };
    }

    if ($p->{group_type}) {
        push @search, 'active_change.group_type' => $p->{group_type};
        push @join, 'active_change';
    }

    if ($p->{group_status}) {
        push @search, 'active_change.status' => $p->{group_status};
        push @join, 'active_change';
    }

    my $m = ($mode == 1?"-or":"-and");

    my $rs = $group_rs->search (
        { $m => \@search },
        {
            join => \@join,
            distinct => 1,
            page => $page,
            rows => 15,
            order_by => 'id'
        }
    );

    my $pager = $rs->pager;
    my @results = $rs->all;

    %{$c->stash} = ( %{$c->stash}, %$p );
    $c->stash->{current_page} = $page;
    $c->stash->{last_page} = $pager->last_page;

    if (scalar (@results) == 0) {
        $c->stash->{error_msg} = "Unable to find any groups that match your search criteria. Please try again.";
        $c->detach ('search_groups');
    }

    $c->stash->{results} = \@results;
    $c->stash->{template} = 'admin/search_groups_results.tt';
}

=head2 search_users

Presents the form to search users.

=cut

sub search_users :Chained('/admin/base') :PathPart('search_users') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'admin/search_users.tt';
}

=head2 do_search_users

Performs a search with the criteria provided and displays the users found.

=cut

sub do_search_users :Chained('/admin/base') :PathPart('search_users/submit') :Args(0) {
    my ($self, $c) = @_;

    my $p = $c->request->params;
    my $account_rs = $c->model("DB::Account");
    my (@search, @join, $page);

    my $current_page = $p->{current_page} || 1;
    my $next = $p->{next};

    if ($next && $next eq 'Next page') {
        $page = $current_page + 1;
    } elsif ($next && $next eq 'Previous page') {
        $page = $current_page - 1;
    } elsif ($next && $next eq 'First page') {
        $page = 1;
    } elsif ($next && $next eq 'Last page') {
        $page = $p->{last_page};
    } else {
        $page = $p->{page} || $current_page;
    }

    if ($p->{accountname}) {
        my $accname = $p->{accountname};
        my $account_search;

        try {
            my $accounts = $c->model('Accounts');
            my $account = $accounts->find_by_name ( $accname );
            my $uid = $account->id;

            $account_search = { 'me.uuid' => $uid };

            if (ref $account eq 'GMS::Schema::Result::Account') {
                $c->stash->{error_msg} = "An error occurred when attempting to communicate with atheme. Data displayed below may not be current.";

                $accname =~ s#_#\\_#g;
                $account_search = {
                    'accountname' => { 'ilike', $accname },
                };
            }
        }
        catch (GMS::Exception $e) {
            $c->stash->{error_msg} = $e->message;
            $account_search = {
                'accountname' => 0,
            };
        }

        push @search, $account_search if ($account_search);
    }

    if ($p->{fullname}) {
        my $name = $p->{fullname};
        $name =~ s#_#\\_#g;

        push @search, {
            'active_change.name' => { ilike => '%' . $name . '%' },
        };
        push @join, { 'contact' => 'active_change' };
    }

    my $rs = $account_rs -> search(
        { -and => \@search },
        {
            join => \@join,
            order_by => 'id',
            page => $page,
            rows => 15,
        }
    );

    my $pager = $rs->pager;
    my @rows = $rs->all;

    %{$c->stash} = ( %{$c->stash}, %$p );
    $c->stash->{current_page} = $page;
    $c->stash->{last_page} = $pager->last_page;

    if ( scalar (@rows) == 0 ) {
        $c->stash->{error_msg} = "Unable to find any users that match your search criteria. Please try again.";
        $c->detach ('search_users');
    }

    my @results;

    # TODO move this to the model
    foreach my $row (@rows) {
        my $account = $c->model('Accounts')->find_by_uid ( $row->id );

        if (ref $account eq 'GMS::Schema::Result::Account') {
            $c->stash->{error_msg} = "An error occurred when attempting to communicate with atheme. Data displayed below may not be current.";
        }
        push @results, $account;
    }

    $c->stash->{results} = \@results;
    $c->stash->{template} = "admin/search_users_results.tt";

}

=head2 search_namespaces

Presents the form to search namespaces.

=cut

sub search_namespaces :Chained('/admin/base') :PathPart('search_namespaces') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'admin/search_namespaces.tt';
}

=head2 do_search_namespaces

Performs a search with the criteria provided and displays the namespaces found.

=cut

sub do_search_namespaces :Chained('/admin/base') :PathPart('search_namespaces/submit') :Args(0) {
    my ($self, $c) = @_;

    my $p = $c->request->params;

    my (@search, @join, $page);
    my $search_item = $p->{search_item};

    my $namespace_rs;

    if ($search_item == 1) {
        $namespace_rs = $c->model("DB::ChannelNamespace");
    } elsif ($search_item == 2) {
        $namespace_rs = $c->model("DB::CloakNamespace");
    }

    my $current_page = $p->{current_page} || 1;
    my $next = $p->{next};

    if ($next && $next eq 'Next page') {
        $page = $current_page + 1;
    } elsif ($next && $next eq 'Previous page') {
        $page = $current_page - 1;
    } elsif ($next && $next eq 'First page') {
        $page = 1;
    } elsif ($next && $next eq 'Last page') {
        $page = $p->{last_page};
    } else {
        $page = $p->{page} || $current_page;
    }

    my $namespace = $p->{namespace};
    $namespace =~ s#_#\\_#g; #escape _ so it's not used as a wildcard.

    my $rs = $namespace_rs -> search(
        { 'namespace' => { 'ilike' => '%' . $namespace . '%' } },
        {
            page => $page,
            rows => 15,
            order_by => 'id'
        }
    );

    my $pager = $rs->pager;
    my @results = $rs->all;

    %{$c->stash} = ( %{$c->stash}, %$p );
    $c->stash->{current_page} = $page;
    $c->stash->{last_page} = $pager->last_page;

    if ( scalar (@results) == 0 ) {
        $c->stash->{error_msg} = "Unable to find any namespaces that match your search criteria. Please try again.";
        $c->detach ('search_namespaces');
    }

    $c->stash->{results} = \@results;
    $c->stash->{template} = "admin/search_namespaces_results.tt";

}

=head2 view

Displays information about a single group.

=cut

sub view :Chained('single_group') :PathPart('view') :Args(0) {
    my ($self, $c) = @_;

    my $group = $c->stash->{group};

    if ($group->status eq 'submitted' || $group->status eq 'pending_web') {
        $c->stash->{friendly_status} = "Submitted, awaiting verification by Group Contact.";
    }
    elsif ($group->status eq "pending_auto" || $group->status eq "pending_staff" || $group->status eq "verified") {
        $c->stash->{friendly_status} = "Awaiting staff decision.";
    }
    elsif ($group->status eq "active") {
        $c->stash->{friendly_status} = "The group is active.";
    }
    elsif ($group->status eq "deleted") {
        $c->stash->{friendly_status} = "The group has been deleted.";
    }

    $c->stash->{template} = 'admin/view_group.tt';
}

=head2 view_account

Displays account & contact information about a user,
admins can view more information than staff.

=cut

sub view_account :Chained('account') :PathPart('view') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'admin/view_account.tt';
}

1;
