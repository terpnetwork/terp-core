use proc_macro2::Span;
use syn::Error;

use crate::parsers::{CircuitAttributes, CircuitTypeAttr};

/// Validation result containing any errors that occurred
#[derive(Debug)]
pub struct ValidationResult {
    pub is_valid: bool,
    pub errors: Vec<Error>,
}

impl ValidationResult {
    /// Create a new valid validation result
    pub fn new() -> Self {
        ValidationResult {
            is_valid: true,
            errors: Vec::new(),
        }
    }

    /// Add an error to the validation result
    pub fn add_error(&mut self, error: Error) {
        self.is_valid = false;
        self.errors.push(error);
    }

    /// Convert all errors into a single compile error TokenStream
    pub fn to_compile_error(&self) -> proc_macro2::TokenStream {
        self.errors
            .iter()
            .fold(proc_macro2::TokenStream::new(), |mut acc, err| {
                acc.extend(err.to_compile_error());
                acc
            })
    }
}

impl Default for ValidationResult {
    fn default() -> Self {
        Self::new()
    }
}

/// Validate circuit attributes against semantic constraints
///
/// ## Validation Rules
/// - `k`: Must be in range [11, 20]
/// - `instances`: Must be in range [1, 255]
/// - `circuit_type`: Must be a known type (Plonkish)
/// - `footer_version`: Must be >= 2 for CS support when analyze_cs is true
pub fn validate_attributes(attrs: &CircuitAttributes, span: Span) -> ValidationResult {
    let mut result = ValidationResult::new();

    // Validate k: must be in range [11, 20]
    if attrs.k < 11 || attrs.k > 20 {
        result.add_error(Error::new(
            span,
            format!(
                "Circuit size parameter k must be in range [11, 20], got {}. \
                 k=11 gives 2048 rows, k=20 gives ~1M rows.",
                attrs.k
            ),
        ));
    }

    // Validate instances: must be in range [1, 255]
    if attrs.instances == 0 {
        result.add_error(Error::new(
            span,
            "Instance count must be at least 1 (got 0). Every circuit needs at least one public input.",
        ));
    }
    // Note: instances is u8 so max is 255, no need to check upper bound

    // Validate circuit type is known
    match attrs.circuit_type {
        CircuitTypeAttr::Plonkish => {
            // Valid
        }
    }

    // Validate footer_version compatibility with analyze_cs
    if attrs.analyze_cs && attrs.footer_version < 2 {
        result.add_error(Error::new(
            span,
            format!(
                "footer_version must be >= 2 when analyze_cs is true (CS-inclusive format). \
                 Got footer_version={}. Set footer_version = 2 or analyze_cs = false.",
                attrs.footer_version
            ),
        ));
    }

    // Validate footer_version range
    if attrs.footer_version < 1 || attrs.footer_version > 2 {
        result.add_error(Error::new(
            span,
            format!(
                "footer_version must be 1 or 2, got {}. \
                 Version 1 = legacy format, Version 2 = CS-inclusive format.",
                attrs.footer_version
            ),
        ));
    }

    result
}

/// Verify that the struct can be used as a circuit
pub fn validate_circuit_struct(input: &syn::DeriveInput) -> ValidationResult {
    let mut result = ValidationResult::new();

    // Check that it's a struct
    match input {
        syn::DeriveInput {
            data: syn::Data::Struct(_),
            ..
        } => {
            // Valid struct
        }
        _ => {
            result.add_error(Error::new_spanned(
                input,
                "#[cosmwasm_circuit] can only be applied to structs",
            ));
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parsers::CircuitAttributes;
    use proc_macro2::Span;

    fn make_attrs(
        k: u32,
        instances: u8,
        footer_version: u8,
        analyze_cs: bool,
    ) -> CircuitAttributes {
        CircuitAttributes {
            k,
            instances,
            circuit_type: CircuitTypeAttr::Plonkish,
            footer_version,
            analyze_cs,
        }
    }

    #[test]
    fn valid_minimal_attributes() {
        let attrs = make_attrs(17, 2, 2, true);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(result.is_valid);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn k_too_small() {
        let attrs = make_attrs(10, 2, 2, true);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(!result.is_valid);
        assert!(result
            .errors
            .iter()
            .any(|e| e.to_string().contains("k must be in range")));
    }

    #[test]
    fn k_too_large() {
        let attrs = make_attrs(21, 2, 2, true);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(!result.is_valid);
        assert!(result
            .errors
            .iter()
            .any(|e| e.to_string().contains("k must be in range")));
    }

    #[test]
    fn instances_zero() {
        let attrs = make_attrs(17, 0, 2, true);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(!result.is_valid);
        assert!(result
            .errors
            .iter()
            .any(|e| e.to_string().contains("Instance count must be at least 1")));
    }

    #[test]
    fn footer_version_mismatch() {
        let attrs = make_attrs(17, 2, 1, true);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(!result.is_valid);
        assert!(result
            .errors
            .iter()
            .any(|e| e.to_string().contains("footer_version must be >= 2")));
    }

    #[test]
    fn legacy_mode_valid() {
        // analyze_cs = false allows footer_version = 1
        let attrs = make_attrs(17, 2, 1, false);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(result.is_valid);
    }

    #[test]
    fn invalid_footer_version() {
        let attrs = make_attrs(17, 2, 3, false);
        let result = validate_attributes(&attrs, Span::call_site());
        assert!(!result.is_valid);
        assert!(result
            .errors
            .iter()
            .any(|e| e.to_string().contains("footer_version must be 1 or 2")));
    }
}
