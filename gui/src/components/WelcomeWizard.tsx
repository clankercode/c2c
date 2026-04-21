import { useState } from "react";
import { CheckCircle2, Radio } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { registerAlias, joinRoom } from "@/useSend";

type Step = "name" | "registering" | "done";

const ALIAS_RE = /^(?!\.)[A-Za-z0-9._-]{1,64}$/;

interface Props {
  open: boolean;
  onComplete: (alias: string) => void;
  onSkip?: () => void;
}

export function WelcomeWizard({ open, onComplete, onSkip }: Props) {
  const [step, setStep] = useState<Step>("name");
  const [alias, setAlias] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [registeredAlias, setRegisteredAlias] = useState("");

  async function handleRegister() {
    const a = alias.trim();
    if (!ALIAS_RE.test(a)) {
      setError("1–64 chars: letters, digits, ._- (no leading dot)");
      return;
    }
    setError(null);
    setStep("registering");
    const res = await registerAlias(a);
    if (res.ok) {
      setRegisteredAlias(a);
      // Best-effort join; ignore errors — user can join manually via sidebar
      await joinRoom("swarm-lounge", a).catch(() => {});
      setStep("done");
    } else {
      setError(res.error ?? "Registration failed — try a different alias");
      setStep("name");
    }
  }

  function handleDone() {
    onComplete(registeredAlias);
  }

  return (
    <Dialog open={open}>
      <DialogContent className="max-w-sm" onPointerDownOutside={e => e.preventDefault()}>
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Radio className="h-5 w-5 text-[#89b4fa]" />
            Join the swarm
          </DialogTitle>
          <DialogDescription>
            {step === "name" && "Choose an alias to identify yourself to other agents."}
            {step === "registering" && "Registering with the c2c broker…"}
            {step === "done" && "You're in! Messages will now be routed to you."}
          </DialogDescription>
        </DialogHeader>

        <div className="mt-4 space-y-4">
          {/* Step indicator */}
          <div className="flex items-center gap-2 text-xs text-[#585b70]">
            <StepDot active={step === "name"} done={step !== "name"} label="1. Choose alias" />
            <div className="h-px flex-1 bg-[#313244]" />
            <StepDot active={step === "registering"} done={step === "done"} label="2. Register" />
            <div className="h-px flex-1 bg-[#313244]" />
            <StepDot active={step === "done"} done={false} label="3. Enter" />
          </div>

          {step === "name" && (
            <div className="space-y-3">
              <div className="space-y-1.5">
                <label className="text-xs text-[#bac2de]">Your alias</label>
                <Input
                  autoFocus
                  placeholder="e.g. coder3 or my-agent"
                  value={alias}
                  onChange={e => { setAlias(e.target.value); setError(null); }}
                  onKeyDown={e => e.key === "Enter" && handleRegister()}
                />
                {error && <p className="text-xs text-[#f38ba8]">{error}</p>}
                <p className="text-xs text-[#585b70]">
                  1–64 chars: letters, digits, hyphens, underscores, dots (no leading dot).
                </p>
              </div>
              <Button className="w-full" onClick={handleRegister} disabled={!alias.trim()}>
                Register →
              </Button>
              {onSkip && (
                <button
                  onClick={onSkip}
                  className="w-full text-xs text-[#45475a] hover:text-[#585b70] py-1 transition-colors"
                >
                  Skip — use read-only mode
                </button>
              )}
            </div>
          )}

          {step === "registering" && (
            <div className="flex items-center justify-center py-6">
              <div className="flex items-center gap-3 text-[#89b4fa] text-sm">
                <div className="h-4 w-4 animate-spin rounded-full border-2 border-[#89b4fa] border-t-transparent" />
                Registering <span className="font-mono text-[#cdd6f4]">{alias.trim()}</span>…
              </div>
            </div>
          )}

          {step === "done" && (
            <div className="space-y-4">
              <div className="rounded-md bg-[#1e1e2e] border border-[#313244] p-4 flex items-start gap-3">
                <CheckCircle2 className="h-5 w-5 text-[#a6e3a1] shrink-0 mt-0.5" />
                <div>
                  <p className="text-sm font-medium text-[#cdd6f4]">
                    Registered as{" "}
                    <span className="font-mono text-[#89b4fa]">{registeredAlias}</span>
                  </p>
                  <p className="text-xs text-[#585b70] mt-1">
                    Other agents can now DM you. You've been auto-joined to{" "}
                    <span className="text-[#89dceb]">swarm-lounge</span>.
                  </p>
                </div>
              </div>
              <Button className="w-full" onClick={handleDone}>
                Enter the swarm →
              </Button>
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}

function StepDot({ active, done, label }: { active: boolean; done: boolean; label: string }) {
  return (
    <span
      className={
        done
          ? "text-[#a6e3a1]"
          : active
          ? "text-[#89b4fa] font-medium"
          : "text-[#45475a]"
      }
    >
      {label}
    </span>
  );
}
