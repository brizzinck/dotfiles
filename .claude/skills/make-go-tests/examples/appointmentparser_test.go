package parser_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/example/hospital/internal/application/parser"
	"github.com/example/hospital/internal/domain"
)

func TestFromRecord(t *testing.T) {
	t.Run(
		"when record has all fields / then maps to appointment correctly",
		func(t *testing.T) {
			const (
				appointmentID = 42
				departmentID  = 7
				patientName   = "Jane Doe"
				durationMins  = 30
			)
			scheduledAt := time.Date(2026, 3, 15, 10, 0, 0, 0, time.UTC)
			notesJSON := []byte(`[
	"follow-up required",
	"allergic to penicillin"
]`)

			row := parser.AppointmentRow{
				ID:           appointmentID,
				PatientName:  patientName,
				DepartmentID: departmentID,
				ScheduledAt:  scheduledAt,
				DurationMins: durationMins,
				NotesJSON:    notesJSON,
				Cancelled:    false,
			}

			appointment, err := parser.FromRecord(row)
			require.NoError(t, err, "valid record should parse without error")

			expected := domain.Appointment{
				ID:           appointmentID,
				PatientName:  patientName,
				DepartmentID: departmentID,
				ScheduledAt:  scheduledAt,
				DurationMins: durationMins,
				Notes:        []string{"follow-up required", "allergic to penicillin"},
				Cancelled:    false,
			}
			assert.Equal(t, expected, *appointment, "appointment should map all fields correctly")
		})

	t.Run(
		"when patient name is empty / then returns ErrInvalidRecord",
		func(t *testing.T) {
			row := parser.AppointmentRow{
				ID:          1,
				PatientName: "",
			}

			appointment, err := parser.FromRecord(row)
			require.Error(t, err, "empty patient name should return an error")
			assert.ErrorIs(t, err, parser.ErrInvalidRecord, "error should wrap ErrInvalidRecord")
			assert.Nil(t, appointment, "appointment should be nil on error")
		})

	t.Run(
		"when notes JSON is malformed / then returns ErrInvalidRecord",
		func(t *testing.T) {
			const patientName = "John Smith"
			row := parser.AppointmentRow{
				ID:          2,
				PatientName: patientName,
				NotesJSON:   []byte(`not valid json`),
			}

			appointment, err := parser.FromRecord(row)
			require.Error(t, err, "malformed notes JSON should return an error")
			assert.ErrorIs(t, err, parser.ErrInvalidRecord, "error should wrap ErrInvalidRecord")
			assert.Nil(t, appointment, "appointment should be nil on error")
		})

	t.Run(
		"when notes JSON is absent / then notes field is empty",
		func(t *testing.T) {
			const (
				appointmentID = 3
				patientName   = "Bob Martinez"
			)
			row := parser.AppointmentRow{
				ID:          appointmentID,
				PatientName: patientName,
			}

			appointment, err := parser.FromRecord(row)
			require.NoError(t, err, "record without notes should parse without error")
			assert.Empty(t, appointment.Notes, "notes should be empty when JSON is absent")
		})
}
