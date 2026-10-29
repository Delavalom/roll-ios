# ADR-0002: No performance claims in copy

**Status:** accepted, 2026-10-22

## Context

App Store Review guideline 2.3 (accurate metadata) rejects apps that claim to speed up, boost, or free memory on a device. The Monitor screen shows live device stats, and "cleaner" apps are scrutinized.

## Decision

- Monitor is read-only. It shows readings and never offers to optimize anything.
- Copy never uses "boost", "free RAM", "speed up", "optimize your phone" or similar.
- The Monitor footer reads: "Live readings from your iPhone. Roll doesn't change how your phone runs."
- Storage claims are about photos and videos only, and always "about X GB".

## Consequences

Marketing and store text must follow this rule. Reviewers check new strings against it.
