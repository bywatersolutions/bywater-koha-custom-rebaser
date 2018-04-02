#!/usr/bin/env perl

use feature 'say';
use warnings;
use strict;

my $branches = {
    barcodeprfx => 'BARCODE PREFIXES',
    bluehill    => 'BLUEHILL',
#   huntsville  => 'HCPL',
    masscat     => 'MASSCAT',
    mdah        => 'MDAH',
    mtpl        => 'MTPL',
    pacifica    => 'PACIFICA',
    plano       => 'PLANO',
    roundrock   => 'ROUND ROCK',
    sdlaw       => 'SDLAW',
    switch      => 'SWITCH',
    vokal       => 'VOKAL',
    washoe      => 'WASHOE',
};

$ENV{DO_IT} //= 0;
$ENV{DO_IT} = 0; #FIXME DEBUG TEST

die "No ENV set for TRAVIS_BRANCH" unless $ENV{TRAVIS_BRANCH};
die "No ENV set for GITHUB_TOKEN" unless $ENV{GITHUB_TOKEN};
say "TESTING MODE: ENV DO_IT not set to $ENV{GITHUB_TOKEN}" if $ENV{GITHUB_TOKEN};

say "TRAVIS_BRANCH: $ENV{TRAVIS_BRANCH}";
say "DO_IT: $ENV{DO_IT}";

# If run from travis, we only want to run for newly pushed bywater base branches
if ( $ENV{TRAVIS_BRANCH} ) {
    unless ( $ENV{TRAVIS_BRANCH} =~ /^bywater-v/ ) {
        say "Not a base ByWater branch, exiting.";
        exit 0;
    }
}

qx{ git remote rm github };
qx{ git remote add github https://$ENV{GITHUB_TOKEN}\@github.com/bywatersolutions/bywater-koha.git };
qx{ git fetch --all };

my @failed_branches;

my $head = qx{ git rev-parse HEAD };
$head =~ s/^\s+|\s+$//g;    # Trim whitespace
say "HEAD: $head";

foreach my $branch_key ( keys %$branches ) {
    say "\nWORKING ON $branch_key";
    my $branch_to_rebase = qx{ git branch -r | grep $branch_key | tail -1 };
    say "FOUND *$branch_to_rebase*";
    $branch_to_rebase =~ s/^\s+|\s+$//g;    # Trim whitespace from both ends
    say "AFTER CLEANUP: *$branch_to_rebase*";

    my ( $branch_to_rebase_remote, $branch_to_rebase_branch ) =
      split( '/', $branch_to_rebase );

    qx{ git checkout $branch_to_rebase };

    my $last_commit_before_cherry_picks = qx{ git log --grep='BWS-PKG - Set bwsbranch to bywater-v' --pretty=format:"%H" --no-patch | head -n 1 };
    $last_commit_before_cherry_picks =~ s/^\s+|\s+$//g;
    my $last_commit_before_cherry_picks_oneline = qx{ git log --grep='BWS-PKG - Set bwsbranch to bywater-v' --pretty=oneline --no-patch | head -n 1 };
    $last_commit_before_cherry_picks_oneline =~ s/^\s+|\s+$//g;
    say "LAST COMMIT BEFORE CHERRY PICKS: $last_commit_before_cherry_picks_oneline";

    my @commits_since = qx{ git rev-list $last_commit_before_cherry_picks..HEAD };
    $_ =~ s/^\s+|\s+$//g for @commits_since;

    my $last_commit = $commits_since[1]; # skip 0, it's the bwsbranch commit
    my $first_commit = $commits_since[-1];
    say "FIRST COMMIT: $first_commit";
    say "LAST COMMIT: $last_commit";

    qx{ git checkout $head };
    qx{ git cherry-pick $first_commit^..$last_commit };
    if ( $? == 0 ) {
        say "CHERRY PICK SUCCESSFUL";

        qx{ sed -i -e 's/bywater/$branch_key/' misc/bwsbranch };
        my $branch_descriptor = $branches->{$branch_key};
        my $branch = qx{ cat misc/bwsbranch };
        qx{ git commit -a -m "$branch_descriptor - Set bwsbranch to $branch" };
        say "COMMITED bwsbranch UPDATE: " . qx{ git rev-parse HEAD };
        my $new_branch = qx{ cat misc/bwsbranch };

        if ( $ENV{DO_IT} ) {
            say "PUSHING NEW BRANCH $new_branch";
            qx{ git push github HEAD:refs/heads/$new_branch -f };
        } else {
            say "DEBUG MODE: NOT PUSHING $new_branch";
        }

    } else {
        say "CHERRY PICK FAILED";
        push( @failed_branches, $branch_to_rebase_branch );
        qx{ git cherry-pick --abort };
    }

    qx{ git reset --hard }; # Not necessary, but just in case
    qx{ git checkout $head };
}

qx{ git remote remove github };

if ( @failed_branches ) {
    say "\n\nSOME BRANCHES FAILED TO AUTO-REBASE";
    say $_ for @failed_branches;
    exit 1;
} else {
    say "\n\nALL BRANCHES AUTO-REBASED SUCCESSFULLY!";
    exit 0;
}
