package saml

import (
	"encoding/xml"
	"fmt"
	"net/url"
	"testing"
	"time"
)

// Exercise the post-signature validation seam named in GO-2026-6909 and the
// XML decoder used by the real SAML provider, including accepted controls.
// https://github.com/golang/vulndb/issues/6909
func releaseFactorySAMLAssertion() (*ServiceProvider, *Assertion, time.Time) {
	now := time.Unix(1800000000, 0).UTC()
	sp := &ServiceProvider{
		EntityID:          "https://sp.example.test/metadata",
		AcsURL:            url.URL{Scheme: "https", Host: "sp.example.test", Path: "/acs"},
		IDPMetadata:       &EntityDescriptor{EntityID: "https://idp.example.test"},
		AllowIDPInitiated: true,
	}
	assertion := &Assertion{
		IssueInstant: now,
		Issuer:       Issuer{Value: sp.IDPMetadata.EntityID},
		Subject: &Subject{
			NameID: &NameID{Value: "alice@example.test"},
			SubjectConfirmations: []SubjectConfirmation{{
				Method: "urn:oasis:names:tc:SAML:2.0:cm:bearer",
				SubjectConfirmationData: &SubjectConfirmationData{
					Recipient: sp.AcsURL.String(), NotOnOrAfter: now.Add(time.Hour),
				},
			}},
		},
		Conditions: &Conditions{
			NotBefore: now.Add(-time.Minute), NotOnOrAfter: now.Add(time.Hour),
			AudienceRestrictions: []AudienceRestriction{{Audience: Audience{Value: sp.EntityID}}},
		},
	}
	return sp, assertion, now
}

func TestReleaseFactorySAMLRequiredElements(t *testing.T) {
	sp, assertion, now := releaseFactorySAMLAssertion()
	if err := sp.validateAssertion(assertion, nil, now); err != nil {
		t.Fatalf("valid assertion rejected: %v", err)
	}
	for name, remove := range map[string]func(*Assertion){
		"Subject":    func(a *Assertion) { a.Subject = nil },
		"Conditions": func(a *Assertion) { a.Conditions = nil },
		"SubjectConfirmationData": func(a *Assertion) {
			a.Subject.SubjectConfirmations[0].SubjectConfirmationData = nil
		},
		"Issuer": func(a *Assertion) { a.Issuer = Issuer{} },
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if value := recover(); value != nil {
					t.Fatalf("missing %s panicked: %v", name, value)
				}
			}()
			sp, assertion, now := releaseFactorySAMLAssertion()
			remove(assertion)
			if err := sp.validateAssertion(assertion, nil, now); err == nil {
				t.Fatalf("missing %s was accepted", name)
			}
		})
	}
}

func TestReleaseFactorySAMLNameIDNamespace(t *testing.T) {
	const namespace = "urn:oasis:names:tc:SAML:2.0:assertion"
	for _, holder := range []string{"Subject", "SubjectConfirmation", "AttributeValue"} {
		for _, nameIDNamespace := range []string{namespace, "urn:foreign", ""} {
			t.Run(holder+"/"+nameIDNamespace, func(t *testing.T) {
				data := []byte(fmt.Sprintf(
					`<saml:%s xmlns:saml="%s"><NameID xmlns="%s">alice@example.test</NameID></saml:%s>`,
					holder, namespace, nameIDNamespace, holder))
				var nameID *NameID
				switch holder {
				case "Subject":
					var value Subject
					if err := xml.Unmarshal(data, &value); err != nil {
						t.Fatal(err)
					}
					nameID = value.NameID
				case "SubjectConfirmation":
					var value SubjectConfirmation
					if err := xml.Unmarshal(data, &value); err != nil {
						t.Fatal(err)
					}
					nameID = value.NameID
				case "AttributeValue":
					var value AttributeValue
					if err := xml.Unmarshal(data, &value); err != nil {
						t.Fatal(err)
					}
					nameID = value.NameID
				}
				if nameIDNamespace == namespace {
					if nameID == nil || nameID.Value != "alice@example.test" {
						t.Fatal("valid SAML NameID rejected")
					}
				} else if nameID != nil {
					t.Fatalf("accepted a NameID outside the SAML namespace: %q", nameID.Value)
				}
			})
		}
	}
}
