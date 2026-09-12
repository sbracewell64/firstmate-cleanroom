package citest

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kunchenguid/no-mistakes/internal/pipeline/steps"
)

// Copied into the supplied producer fixture's citest package for private pairing.
// The exact artifact supplies qualification reads; unchanged producer source
// supplies SQLite/CI effects with fake forge transport. No daemon/model runs.
func TestFirstmateExactQualificationPairing(t *testing.T) {
	firstmateQualificationPairing(t, "qualification-pairing.sh")
}

func TestFirstmatePreviousQualificationRace(t *testing.T) {
	firstmateQualificationPairing(t, "qualification-red.sh")
}

func firstmateQualificationPairing(t *testing.T, script string) {
	binary := os.Getenv("NM_QUALIFICATION_TEST_BINARY")
	root := os.Getenv("FM_QUALIFICATION_CONSUMER_ROOT")
	raw, err := os.ReadFile(binary)
	if err != nil || fmt.Sprintf("%x", sha256.Sum256(raw)) != os.Getenv("NM_QUALIFICATION_TEST_SHA256") {
		t.Fatalf("mandatory exact artifact unavailable or digest differs: %v", err)
	}
	s, home := qualificationContext(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Ctx = ctx
	step := (&steps.CIStep{}).SetWaitForNextPoll(func(context.Context, time.Duration) error {
		q, err := s.DB.CurrentCIQualification(s.Run.ID, s.Run.HeadSHA, "", "")
		if err != nil {
			t.Fatal(err)
		}
		evidence := os.Getenv("FM_PAIR_EVIDENCE_DIR")
		if evidence == "" {
			t.Fatal("durable private FM_PAIR_EVIDENCE_DIR is required")
		}
		lab := filepath.Join(evidence, t.Name())
		if err := os.Mkdir(lab, 0700); err != nil {
			t.Fatal(err)
		}
		b, err := json.Marshal(q)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(lab, "qualification.json"), b, 0600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("bash", filepath.Join(root, "tests/laboratory", script), lab, home, s.WorkDir)
		cmd.Dir = s.WorkDir
		cmd.Env = append(os.Environ(), s.Env...)
		cmd.Env = append(cmd.Env, "FM_QUALIFICATION_CONSUMER_ROOT="+root)
		done := make(chan error, 1)
		go func() {
			deadline := time.Now().Add(300 * time.Second)
			for time.Now().Before(deadline) {
				if _, err := os.Stat(filepath.Join(lab, "race-ready")); err == nil {
					c := strings.Repeat("c", 40)
					if err := s.DB.UpdateRunHeadSHAForRevalidation(q.Run, c); err != nil {
						done <- err
						return
					}
					if err := os.WriteFile(filepath.Join(lab, "canonical-head"), []byte(c), 0600); err != nil {
						done <- err
						return
					}
					done <- os.WriteFile(filepath.Join(lab, "race-release"), nil, 0600)
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			done <- fmt.Errorf("actual-stage interleaving never reached producer boundary")
		}()
		out, err := cmd.CombinedOutput()
		if writeErr := os.WriteFile(filepath.Join(lab, "consumer.log"), out, 0600); writeErr != nil {
			t.Fatal(writeErr)
		}
		t.Logf("consumer/exact-artifact pairing:\n%s", out)
		if err != nil {
			t.Fatalf("consumer pairing: %v", err)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		cancel()
		return ctx.Err()
	})
	if _, err := step.Execute(s); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
