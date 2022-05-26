#!/usr/bin/env perl

use feature 'say';
use warnings;
use strict;

use File::Slurp;
use FindBin qw($Bin);
use JSON;
use LWP::UserAgent;

my $json     = from_json( read_file("$Bin/branches.json") );
my $branches = $json->{branches};

$ENV{DO_IT} //= 0;
$ENV{GITHUB_REPOSITORY} //= "bywatersolutions/bywater-koha";

die "No ENV set for KOHA_BRANCH" unless $ENV{KOHA_BRANCH};
die "No ENV set for GITHUB_TOKEN"  unless $ENV{GITHUB_TOKEN};

say "GITHUB_REPOSITORY: $ENV{GITHUB_REPOSITORY}";
say "KOHA_BRANCH: $ENV{KOHA_BRANCH}";
say "DO_IT: $ENV{DO_IT}";

say "RUNNING IN TEST MODE: Rebased branches will not be pushed!"
  unless $ENV{DO_IT};

# If run from travis, we only want to run for newly pushed bywater base branches
if ( $ENV{KOHA_BRANCH} ) {
    unless ( $ENV{KOHA_BRANCH} =~ /^bywater-v/ ) {
        say "Not a base ByWater branch, exiting.";
        exit 0;
    }
}

my $ua = LWP::UserAgent->new;

say "Setting /kohaclone dir as safe directory";
qx{ git config --global --add safe.directory /kohaclone };
say "Removing existing github repo, if any";
qx{ git remote rm github };
say "Adding github repo";
qx{ git remote add github https://$ENV{GITHUB_TOKEN}\@github.com/$ENV{GITHUB_REPOSITORY}.git };
say "Fetching github remote";
qx{ git fetch -v --progress github };
say "Done fetching github remote";

my @failed_branches;

my $head = qx{ git rev-parse HEAD };
$head =~ s/^\s+|\s+$//g;    # Trim whitespace
say "HEAD: $head";
my $heads = { bywater => $head };

if ( $ENV{SLACK_URL_NEW_COMMITS} ) {
    my @commits = qx{ git log --pretty=format:'%s' --no-patch | head -n 500 };
    pop @commits;    # Get rid of our first bwsbranch commit
    foreach my $c (@commits) {
        if ( $c =~ /bwsbranch/ ) {
            last; # Stop when we get to the previous bwsbranch commit
        }
        else {
            say "FOUND NEW COMMIT: $c";
            $ua->post(
                $ENV{SLACK_URL_NEW_COMMITS},
                Content_Type => 'application/json',
                Content =>
                  to_json( { text => "`$c` added to `$ENV{KOHA_BRANCH}`" } ),
            );
        }
    }
}

foreach my $branch (@$branches) {
    my $branch_name    = $branch->{name};
    my $message_prefix = $branch->{message_prefix};
    my $base_branch    = $branch->{base_branch};
    my $stop_commit    = $branch->{stop_commit};

    $base_branch ||= 'bywater';
    $stop_commit ||= 'BWS-PKG - Set bwsbranch to bywater-v';

    say "\nWORKING ON $branch_name";
    $head = $heads->{$base_branch};

    my $branch_to_rebase = qx{ git branch -r | grep $branch_name- | tail -1 };
    say "FOUND *$branch_to_rebase*";
    $branch_to_rebase =~ s/^\s+|\s+$//g;    # Trim whitespace from both ends
    say "AFTER CLEANUP: *$branch_to_rebase*";

    my ( $branch_to_rebase_remote, $branch_to_rebase_branch ) =
      split( '/', $branch_to_rebase );

    qx{ git checkout $branch_to_rebase };

    my $last_commit_before_cherry_picks = qx{ git log --grep='$stop_commit' --pretty=format:"%H" --no-patch | head -n 1 };
    $last_commit_before_cherry_picks =~ s/^\s+|\s+$//g;
    my $last_commit_before_cherry_picks_oneline = qx{ git log --grep='$stop_commit' --pretty=oneline --no-patch | head -n 1 };
    $last_commit_before_cherry_picks_oneline =~ s/^\s+|\s+$//g;
    say "LOOKING FOR STOP COMMIT: " . $stop_commit;
    say "LAST COMMIT BEFORE CHERRY PICKS: $last_commit_before_cherry_picks_oneline";

    my @commits_since =
      qx{ git rev-list $last_commit_before_cherry_picks..HEAD };
    $_ =~ s/^\s+|\s+$//g for @commits_since;

    shift @commits_since;    # skip first commit, it's the bwsbranch commit

    qx{ git checkout $head };
    my @commits = reverse(@commits_since);
    my $success = 1;
    foreach my $commit (@commits) {
        my $output = qx{ git cherry-pick $commit };
        say "CHERRY PICK OUTPUT: $output";

        if ( $? == 0 ) {
            say "CHERRY PICK $commit SUCCESSFUL";
        }
        elsif ( $output =~ /The previous cherry-pick is now empty/ ) {
            qx{ git reset };
        }
        else {
            $success = 0;
            say "CHERRY PICK $commit FAILED";
        }

        last unless $success;
    }

    if ($success) {
        qx{ sed -i -e 's/$base_branch/$branch_name/' misc/bwsbranch };
        my $branch = qx{ cat misc/bwsbranch };
        qx{ git commit -a -m "$message_prefix - Set bwsbranch to $branch" };
        say "COMMITED bwsbranch UPDATE: " . qx{ git rev-parse HEAD };
        my $new_branch = qx{ cat misc/bwsbranch };

        if ( $ENV{DO_IT} ) {
            say "PUSHING NEW BRANCH $new_branch";
            qx{ git push -f github HEAD:refs/heads/$new_branch };

            my $new_head = qx{ git rev-parse HEAD };
            $new_head =~ s/^\s+|\s+$//g;    # Trim whitespace
            $heads->{$branch_name} = $new_head;

            say "Fetching remotes";
            qx{ git fetch --all };
            say "Done fetching remotes";
        }
        else {
            say "DEBUG MODE: NOT PUSHING $new_branch";
        }
    }
    else {
        say "FAILED TO AUTO-REBASE $branch_to_rebase_branch";
        push( @failed_branches, $branch_to_rebase_branch );
        qx{ git cherry-pick --abort };
    }

    qx{ git reset --hard };    # Not necessary, but just in case
    qx{ git checkout $heads->{bywater} };
}

qx{ git remote remove github };

if (@failed_branches) {
    say "\n\nSOME BRANCHES FAILED TO AUTO-REBASE";
    say $_ for @failed_branches;
    exit 1;
}
else {
    say "\n\nALL BRANCHES AUTO-REBASED SUCCESSFULLY!";
    exit 0;
}
